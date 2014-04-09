(defgroup polymode-export nil
  "Polymode Exporters"
  :group 'polymode)

(defcustom polymode-export-output-file-format "%s[exported]"
  "Format of the exported files.
%s is substituted with the current file name sans extension.")

(defclass pm-exporter (polymode)
  ((from
    :initarg :from
    :initform '()
    :type list
    :custom list
    :documentation
    "Input specifications. A list of lists of the form (from-id
    extension doc commmand).")
   (to
    :initarg :to
    :initform '() 
    :type list
    :custom list
    :documentation
    "Output specifications. A list of the list of the form (to-id
    extension doc %t-spec).")
   (function
    :initarg :function
    :init-value nil
    :type (or null function)
    :documentation
    "Function to process the commmand. Must take 3 arguments
     COMMAND, FROM and TO. COMMAND is the 4th argument of :from
     spec with all the formats substituted. FROM is the id of
     requested :from spec, TO is the id of the :to spec.")
   (sentinel
    :initarg :sentinel
    :init-value nil
    :type (or null function)
    :documentation
    "Optional sentinel function to be called by :function when a
    shell call is involved.")
   )
  "Root exporter class.")


;; UI
(defvar pm--exporter-hist nil)
(defvar pm--export:from-hist nil)
(defvar pm--export:to-hist nil)

(defun polymode-export (&optional from to)
  ;; with arg, select :from spec
  ;; todo: '(16) should allow for edditing :from command
  ;; todo: store last specs in exporter
  (interactive "P")
  (let* ((exporter (symbol-value (or (oref pm/config :exporter)
                                     (polymode-set-exporter))))
         (e:from (oref exporter :from))
         (e:to (oref exporter :to))
         (from-opts (mapcar (lambda (el)
                              (propertize (nth 2 el) :id (car el)))
                            (oref exporter :from)))
         (to-opts (mapcar (lambda (el)
                            (propertize (format "%s (%s)" (nth 2 el) (nth 1 el))
                                        :id (car el)))
                          (oref exporter :to)))
         (from
          (cond ((null from)
                 (let ((fname (file-name-nondirectory buffer-file-name)))
                   (or (and (pm--oref-hist :export-from)
                            (get-text-property 0 :id (pm--oref-hist :export-from)))
                       (car (cl-rassoc-if (lambda (el)
                                            (string-match-p (car el) fname))
                                          e:from))
                       (let* ((prompt (format "No input spec for '%s'. Choose one: "
                                              (file-name-extension fname)
                                              ;; object-name returns clutter like "#<pm-exporter pandoc>"
                                              ;; use internal implementation:
                                              (if (fboundp 'eieio--object-name)
                                                  (eieio--object-name exporter)
                                                (aref exporter object-name))))
                              (sel (ido-completing-read prompt from-opts nil t nil
                                                        'pm--export:from-hist
                                                        (pm--oref-hist :export-from))))
                         (pm--oset-hist :export-from sel)
                         (get-text-property 0 :id sel)))))
                ;; C-u, force a :from spec
                ((equal from '(4))
                 (let ((sel (ido-completing-read "Input type: " from-opts nil t nil
                                                 'pm--export:from-hist (pm--oref-hist :export-from)) ))
                   (pm--oset-hist :export-from sel)
                   (get-text-property 1 :id sel)))
                ((stringp from)
                 (if (assoc from e:from)
                     from
                   (error "Cannot find input spec '%s' in %s exporter" from (object-name exporter))))
                (t (error "'from' argument must be nil, universal argument or a string"))
                ))
         (to
          (cond ((null to)
                 (let ((sel (ido-completing-read "Choose output spec: " to-opts nil t nil
                                                 'pm--export:to-hist (pm--oref-hist :export-to))))
                   (pm--oset-hist :export-to sel)
                   (get-text-property 1 :id sel)))
                ((stringp to)
                 (if (assoc to e:to)
                     to
                   (error "Cannot find output spec '%s' in %s exporter" to (object-name exporter))))
                (t (error "'to' argument must be nil or a string"))))
         (from-spec (assoc from e:from))
         (to-spec (assoc to e:to))
         (to-file (concat (format polymode-export-output-file-format
                                  (file-name-base buffer-file-name))
                          "." (nth 1 to-spec)))
         (command (format-spec (nth 3 from-spec)
                               (list (cons ?i (file-name-nondirectory buffer-file-name))
                                     (cons ?o to-file)
                                     (cons ?t (nth 3 to-spec))))))
    ;; compunicate with sentinel with local vars to avoid needless clutter
    (set (make-local-variable 'pm--export-output-file) to-file)
    (funcall (oref exporter :function) command from to)))

(defmacro polymode-register-exporter (exporter default? &rest configs)
  "Add EXPORTER to :exporters slot of all config objects in CONFIGS.
When DEFAULT? is non-nil, also make EXPORTER the default exporter for each polymode in CONFIGS."
  `(dolist (pm ,configs)
     (object-add-to-list pm :exporters ,exporter)
     (when ,default? (oset pm :exporter ,exporter))))

(defun polymode-set-exporter ()
  (interactive)
  (unless pm/config
    (error "No pm/config object found. Not in polymode buffer?"))
  (let* ((exporters (pm--abrev-names
                     (delete-dups (pm--oref-with-parents pm/config :exporters))
                     "pm-exporter/"))
         (sel (ido-completing-read "No default exporter. Choose one: " exporters nil t nil
                                   'pm--exporter-hist (oref pm/config :exporter)))
         (out (intern (get-text-property 0 :orig sel))))
    (oset pm/config :exporter out)
    out))


;;; UTILS
(defun pm-default-export-sentinel (process name)
  "default sentinel function"
  (let ((buff (process-buffer process)))
    (with-current-buffer buff
      (goto-char (point-min))
      (let ((case-fold-search t)
            (ofile pm--export-output-file))
        (if (not (re-search-forward "error" nil 'no-error))
            (progn
              (pop-to-buffer pm--input-buffer)
              (display-buffer (find-file-noselect ofile 'nowarn)))
          (kill-buffer )
          (display-buffer (current-buffer))
          (error "Bumps while exporting: %s" name))))
    (kill-buffer buff)))

(defun pm-default-export-function (command from to)
  "Run command interactively.
Run command in a buffer (in comint-shell-mode) so that it accepts
user interaction. This is a default function in all exporters
that call a shell command"
  ;; simplified version of TeX-run-TeX
  (require 'comint)
  (let* (;(default TeX-command-default)
         (name (format "%s-->%s" from to))
         (buffer (get-buffer-create (format "*%s*" name)))
         (process nil)
         (command-buff (current-buffer))
         (ofile pm--export-output-file)
         (sentinel-function (oref (symbol-value (oref pm/config :exporter))
                                  :sentinel)))
    (with-current-buffer buffer
      (read-only-mode -1)
      (erase-buffer)
      (insert "Exporting " name " with command:\n     " command "\n")
      (comint-exec buffer name shell-file-name nil
                   (list shell-command-switch command))
      (comint-mode)
      (setq process (get-buffer-process buffer))
      (set-process-sentinel process sentinel-function)
      ;; communicate with sentinel
      (set (make-local-variable 'pm--export-output-file) ofile)
      (set (make-local-variable 'pm--input-buffer) command-buff)
      (set-marker (process-mark process) (point-max)))
    (pop-to-buffer buffer)))



;;; GLOBAL EXPORTERS
(defcustom pm-exporter/pandoc
  (pm-exporter "pandoc"
               :from
               '(;; ("json"	"\\.json\\'" "JSON native AST"	"pandoc %i -f json -t %t -o %o")
                 ("markdown"	"\\.md\\'" "pandoc's markdown" 	"pandoc %i -f markdown -t %t -o %o")
                 ("markdown_strict"	"\\.md\\'" "original markdown"	"pandoc %i -f markdown_strict -t %t -o %o")
                 ("markdown_phpextra"	"\\.md\\'" "PHP markdown"	"pandoc %i -f markdown_phpextra -t %t -o %o")
                 ("markdown_phpextra"	"\\.md\\'" "github markdown" 	"pandoc %i -f markdown_phpextra -t %t -o %o")
                 ("textile"	"\\.textile\\'" "Textile" 		"pandoc %i -f textile -t %t -o %o")
                 ("rst"		"\\.rst\\'" "reStructuredText"	"pandoc %i -f rst -t %t -o %o")
                 ("html"	"\\.x?html?\\'" "HTML" 	"pandoc %i -f html -t %t -o %o")
                 ("doocbook"	"\\.xml\\'" "DocBook" 		"pandoc %i -f doocbook -t %t -o %o")
                 ("mediawiki"	"\\.wiki\\'" "MediaWiki"		"pandoc %i -f mediawiki -t %t -o %o")
                 ("latex"	"\\.tex\\'" "LaTeX" 		"pandoc %i -f latex -t %t -o %o")
                 )
               :to
               '(;; ("json"  	"json"  "JSON version of native AST" "json")
                 ("plain"  	"txt"  "plain text" "plain")
                 ("markdown"  	"md"  "pandoc's extended markdown" "markdown")
                 ("markdown_strict"  	"md"  "original markdown" "markdown_strict")
                 ("markdown_phpextra"  	"md"  "PHP extended markdown" "markdown_phpextra")
                 ("markdown_github"  	"md"  "github extended markdown" "markdown_github")
                 ("rst"  	"rst"  "reStructuredText" "rst")
                 ("html"  	"html"  "XHTML 1" "html")
                 ("html5"  	"html"  "HTML 5" "html5")
                 ("latex"  	"tex"  "LaTeX" "latex")
                 ("beamer"  	"tex"  "LaTeX beamer" "beamer")
                 ("context"  	"tex"  "ConTeXt" "context")
                 ("man"  	"man"  "groff man" "man")
                 ("mediawiki"  	"wiki"  "MediaWiki markup" "mediawiki")
                 ("textile"  	"textile"  "Textile" "textile")
                 ("org"  	"org"  "Emacs Org-Mode" "org")
                 ("texinfo"  	"info"  "GNU Texinfo" "texinfo")
                 ("docbook"  	"xml"  "DocBook XML" "docbook")
                 ("opendocument"  	"xml"  "OpenDocument XML" "opendocument")
                 ("odt"  	"odt"  "OpenOffice text document" "odt")
                 ("docx"  	"docx"  "Word docx" "docx")
                 ("epub"  	"epub"  "EPUB book" "epub")
                 ("epub3"  	"epub"  "EPUB v3" "epub3")
                 ("fb2"  	"fb"  "FictionBook2 e-book" "fb2")
                 ("asciidoc"  	"txt"  "AsciiDoc" "asciidoc")
                 ("slidy"  	"html"  "Slidy HTML slide show" "slidy")
                 ("slideous"  	"html"  "Slideous HTML slide show" "slideous")
                 ("dzslides"  	"html"  "HTML5 slide show" "dzslides")
                 ("s5"  	"html"  "S5 HTML slide show" "s5")
                 ("rtf"  	"rtf"  "rich text format" "rtf")
                 )
               :function 'pm-default-export-function
               :sentinel 'pm-default-export-sentinel)
  "Pandoc exporter"
  :group 'polymode-export)