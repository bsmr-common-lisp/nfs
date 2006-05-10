(in-package :user)

;; $Id: rpcgen.cl,v 1.4 2006/05/06 19:42:16 dancy Exp $

(eval-when (compile load eval)
  (require :osi))

(defmacro with-input-from-subprocess ((cmd var) &body body)
  `(multiple-value-bind (,var dummy pid)
       (run-shell-command ,cmd :output :stream :wait nil)
     (declare (ignore dummy))
     (unwind-protect
	 (progn ,@body)
       (close ,var)
       (sys:reap-os-subprocess :pid pid))))

(defparameter *optionals-generated* nil)
(defparameter *unread-buffer* nil)
(defparameter *constants* nil)
(defparameter *enums* nil)
(defparameter *structs* nil)
(defparameter *unions* nil)
(defparameter *typedefs* nil)

(defstruct enum
  name
  values)

(defstruct struct
  name
  members)

(defstruct xunion
  name
  discrimtype
  discrimname
  members)

(defstruct typedef
  type
  name
  len) ;; if fixed

(defstruct program
  name
  number
  versions)

(defstruct program-version
  name
  number
  procedures)

(defstruct procedure
  name
  number
  arg-type
  return-type)
  
(defparameter *header* ";; Do not edit this file.  It was automatically generated by rpcgen.cl")

(defun rpcgen (filename)
  (let (programs)
    ;; Generate an error message if the file doesn't exist.
    (close (open filename))
  
    (setf *optionals-generated* nil)
    (setf *unread-buffer* nil)
    (setf *constants* nil)
    (setf *enums* nil)
    (setf *structs* nil)
    (setf *unions* nil)
    (setf *typedefs* nil)
  
    (with-input-from-subprocess
	((format nil "bash -c 'cpp ~a | grep -v ^#'" filename)
	 stream)
    
      (while (rpcgen-peekchar stream)
	(let ((token (rpcgen-lex stream :word)))
	  (cond
	   ((string= token "const")
	    (rpcgen-const stream))
	   ((string= token "enum")
	    (rpcgen-enum stream))
	   ((string= token "typedef")
	    (rpcgen-typedef stream))
	   ((string= token "struct")
	    (rpcgen-struct stream))
	   ((string= token "union")
	    (rpcgen-union stream))
	   ((string= token "program")
	    (push (rpcgen-program stream) programs))
	   (t
	    (error "Unexpected token: ~a" token))))))

    (setf programs (nreverse programs))

    (with-open-file (f 
		     (concatenate 'string (pathname-name filename) "-common.cl")
		     :direction :output
		     :if-exists :supersede)

      (write-line *header* f)
      
      (format f ";; Constants~%~%(eval-when (compile load eval)~%")
      (dolist (const *constants*)
	(multiple-value-bind (varname value)
	    (values-list const)
	  (format f "(defconstant ~a ~a)~%" varname value)))

      (format f "~%~%;; Enums~%~%")
      (dolist (enum *enums*)
	(format f ";; enum ~a~%" (enum-name enum))
	(dolist (pair (enum-values enum))
	  (format f "(defconstant ~a ~a)~%" (car pair) (cdr pair)))
	(format f "~%"))
      (format f ") ;; eval-when~%~%")

      (format f ";; Structs~%~%")
      (dolist (struct *structs*)
	(let ((first t)
	      (indent 
	       (make-string (+ (length (struct-name struct)) 16)
			    :initial-element #\space)))
	  (format f "(defxdrstruct ~a (" (struct-name struct))
	  (dolist (member (struct-members struct))
	    (if* first
	       then (setf first nil)
	       else (format f "~%~a" indent))
	  
	    (multiple-value-bind (slottype slotname varfixed len)
		(values-list member)
	      (format f "(~a ~a" slottype slotname)
	      (if varfixed
		  (format f " ~s ~a" varfixed len))
	
	      (format f ")")))
	
	  (format f "))~%~%")))
    
      (format f ";; Unions~%~%")
      (dolist (union *unions*)
	(format f "(defxdrunion ~a (~a ~a)~% (~%" 
		(xunion-name union) (xunion-discrimtype union)
		(xunion-discrimname union))
	(dolist (member (xunion-members union))
	  (multiple-value-bind (cases type slot)
	      (values-list member)
	    (if* (eq cases :default)
	       then (format f "  (:default ")
	     elseif (= (length cases) 1)
	       then (format f "  (~a " (first cases))
	       else (format f "  (~a " cases))
	    (format f "~a ~a)~%" type slot)))
	(format f " ))~%~%"))
    
      (format f ";; Typedefs~%~%")
      (dolist (enum *enums*)
	(format f "(defun xdr-~a (xdr &optional int)~% (xdr-int xdr int))~%~%"
		(enum-name enum)))

      (dolist (td *typedefs*)
	(if* (typedef-len td)
	   then (format f "(defun xdr-~a (xdr &rest rest)~%  (apply #'xdr-~a-fixed xdr :len #.~a rest))~%~%" 
			(typedef-name td) (typedef-type td) (typedef-len td))
	   else (format f "(defun xdr-~a (xdr &optional data)~%  (xdr-~a xdr data))~%~%" 
			(typedef-name td) (typedef-type td))))
    
      (format f ";; Helpers~%~%")
      (dolist (opt *optionals-generated*)
	(format f "(defun xdr-optional-~a (xdr &optional arg)~%  (xdr-optional xdr #'xdr-~a arg))~%~%" opt opt))
      
      (format f ";; Programs~%~%(eval-when (compile load eval)~%")
      (dolist (program programs)
	(format f ";; ~a~%~%" (program-name program))
	(format f " (defconstant ~a ~d)~%~%" 
		(program-name program) (program-number program))
	(dolist (version (program-versions program))
	  (format f ";; ~a version ~a~%~%" 
		  (program-name program) (program-version-number version))
	  (format f " (defconstant ~a ~d)~%" 
		  (program-version-name version) 
		  (program-version-number version))
	  (dolist (proc (program-version-procedures version))
	    (format f " (defconstant ~a ~d)~%" 
		    (constantify-string (procedure-name proc))
		    (procedure-number proc)))
	  (format f "~%")))
      (format f ") ;; eval-when~%~%"))
    
    (with-open-file (f 
		     (concatenate 'string (pathname-name filename) 
				  "-server.cl")
		     :direction :output
		     :if-exists :supersede)
      
      (write-line *header* f)
      
      (dolist (program programs)
	(format f "(def-rpc-program (~a #.~a)~%" 
		(pathname-name filename) (program-name program))
	(format f "  (~%")
	(dolist (version (program-versions program))
	  (format f "   (#.~a~%" (program-version-name version))
	  (dolist (proc (program-version-procedures version))
	    (format f "     (#.~a ~a ~a ~a)~%" 
		    (constantify-string (procedure-name proc))
		    (procedure-name proc)
		    (procedure-arg-type proc)
		    (procedure-return-type proc)))
	  (format f "   )~%"))
	(format f "  ))~%")))
    
    (with-open-file (f 
		     (concatenate 'string (pathname-name filename) 
				  "-client.cl")
		     :direction :output
		     :if-exists :supersede)
      
      (write-line *header* f)
      
      (dolist (program programs)
	(dolist (version (program-versions program))
	  (dolist (proc (program-version-procedures version))
	    (format f "(defun call-~a-~a (cli arg)~% (callrpc cli ~a #'xdr-~a arg :outproc #'xdr-~a))~%~%"
		    (lispify-string (procedure-name proc))
		    (program-version-number version)
		    (procedure-number proc)
		    (procedure-arg-type proc)
		    (procedure-return-type proc))))))))
		    

(defun rpcgen-unread (thing)
  (if *unread-buffer*
      (error "unread buffer is already used"))
  (setf *unread-buffer* thing))

(defun rpcgen-lex (stream type)
  (when *unread-buffer*
    (let ((res *unread-buffer*))
      (setf *unread-buffer* nil)
      ;; This handles non-matching characters.. or getting
      ;; a character when expecting word.
      (if (and (characterp res) (not (eq res type)))
	  (error "Got ~s when looking for ~s" res type))
      ;; This handles getting a word when expecting a character
      (if (and (characterp type) (stringp res))
	  (error "Got a word when looking for ~s" type))
      ;; Checks okay
      (return-from rpcgen-lex res)))
  
  (let (res char)
    
    ;; Skip any whitespace
    (while (setf char (read-char stream nil nil))
      (if (not (excl::whitespace-char-p char))
	  (return)))
    
    (if char
	(unread-char char stream))
    
    (while (setf char (read-char stream nil nil))
      (if* (or (alphanumericp char) (char= char #\_))
	 then (push char res)
	 else (return)))
    
    (if* res 
       then ;; we just terminated an identifier or reserved word
	    (if char
		(unread-char char stream))
	    
	    (if (not (eq type :word))
		(error "Got a word when looking for ~s" type))
	    
	    (make-array (length res) :element-type 'character
			 :initial-contents (nreverse res))
       else ;; EOF or special character.  Return it.
	    (if (not (eq char type))
		(error "Got ~s when looking for ~s" char type))
	    
	    char)))

(defun rpcgen-peekchar (stream)
  (let (char)
    ;; Skip any whitespace
    (while (setf char (read-char stream nil nil))
      (if (not (excl::whitespace-char-p char))
	  (return)))
    
    (if char
	(unread-char char stream))
    
    char))

(defun parse-number (string neg)
  (when (match-re "^\\d" string)
    (setf string (string-downcase string))
    (if* (prefixp "0x" string)
       then (concatenate 'string "#x" 
			 (if neg "-" "")
			 (subseq string 2))
     elseif (prefixp "0" string)
       then (concatenate 'string "#o" 
			 (if neg "-" "")
			 (subseq string 1))
       else (if* neg 
	       then (concatenate 'string "-" string)
	       else string))))

(defun rpcgen-const (stream)
  (let ((varname (constantify-string (rpcgen-lex stream :word)))
	neg)
    (rpcgen-lex stream #\=)
    
    (when (eq (rpcgen-peekchar stream) #\-)
      (setf neg t)
      (rpcgen-lex stream #\-))
    
    (let* ((expression (rpcgen-lex stream :word))
	   (value (parse-number expression neg)))
      (if (null value)
	  (error "Non-numeric constant declaration."))
      
      (rpcgen-lex stream #\;)
      
      (push `(,varname ,value) *constants*))))
      
;; alternate version.. need to verify that it works when
;; the next word is "opaque" (which .x file used that?)
(defun rpcgen-typedef (stream)
  (multiple-value-bind (type name varfixed len)
      (rpcgen-parse-type-and-name stream)
    (rpcgen-lex stream #\;)

    (push (make-typedef :type type
			:name name
			:len (if (eq :fixed varfixed) len))
	  *typedefs*)))
    
(defun rpcgen-enum (stream)
  (let ((typename (lispify-string (rpcgen-lex stream :word)))
	values)
    (rpcgen-lex stream #\{)

    (loop
      (let ((varname (constantify-string (rpcgen-lex stream :word)))
	    value)
	(rpcgen-lex stream #\=)
	(setf value (parse-integer (rpcgen-lex stream :word)))
	
	(push (cons varname value) values)

	(if (not (eq (rpcgen-peekchar stream) #\,))
	    (return))
	(rpcgen-lex stream #\,)))
    
    (rpcgen-lex stream #\})	
    (rpcgen-lex stream #\;)
    
    (push (make-enum :name typename :values (nreverse values)) *enums*)))

    
(defun rpcgen-struct (stream)
  (let* ((typename (lispify-string (rpcgen-lex stream :word)))
	 members)
    (rpcgen-lex stream #\{)

    (while (not (eq (rpcgen-peekchar stream) #\}))
      (push (multiple-value-list (rpcgen-parse-type-and-name stream))
	    members)
      (rpcgen-lex stream #\;))
    
    (rpcgen-lex stream #\})
    (rpcgen-lex stream #\;)

    (push (make-struct :name typename :members (nreverse members)) *structs*)))
    

(defun rpcgen-union (stream)
  (let ((typename (lispify-string (rpcgen-lex stream :word)))
	current-cases
	members)
    (if (not (string= (rpcgen-lex stream :word) "switch"))
	(error "Syntax error: Expected 'switch'"))

    (rpcgen-lex stream #\()
    (multiple-value-bind (discrimtype discrimname)
	(rpcgen-parse-type-and-name stream)
      (rpcgen-lex stream #\))
      (rpcgen-lex stream #\{)
      
      (while (not (eq (rpcgen-peekchar stream) #\}))      
	(let ((token (rpcgen-lex stream :word)))
	  (cond 
	   ((string= token "case")
	    (let ((case (constantify-string (rpcgen-lex stream :word))))
	      (rpcgen-lex stream #\:)
	      
	      (push (concatenate 'string "#." case) current-cases)
	      
	      ;; next word will be either 'case' or the name of a type.
	      (when (not (string= "case" 
				  (rpcgen-unread (rpcgen-lex stream :word))))
		(multiple-value-bind (type slot)
		    (rpcgen-parse-type-and-name stream)
		  (rpcgen-lex stream #\;)
		  (when (string/= type "void")
		    (push `(,(nreverse current-cases) ,type ,slot) members))
		  (setf current-cases nil)))))
	   ((string= token "default")
	    (rpcgen-lex stream #\:)
	    (multiple-value-bind (type slot)
		(rpcgen-parse-type-and-name stream)
	      (rpcgen-lex stream #\;)
	      
	      (if (string/= type "void")
		  (push `(:default ,type ,slot) members))))
	   (t
	    (error "Unexpected word: ~a" token)))))
      
      (rpcgen-lex stream #\})
      (rpcgen-lex stream #\;)
      
      (push (make-xunion :name typename 
			 :discrimtype discrimtype
			 :discrimname discrimname
			 :members (nreverse members))
	    *unions*))))
      
      

(defun rpcgen-parse-type (stream)
  (let ((type (rpcgen-lex stream :word)))
    (if (string= type "struct")
	(setf type (rpcgen-lex stream :word)))
    (lispify-string type)))



(defun generate-optional-func (type)
  (pushnew type *optionals-generated* :test #'string=))

  
;; returns values:
;;  type, name, variable/fixed, length 
(defun rpcgen-parse-type-and-name (stream)
  (let ((type (rpcgen-parse-type stream)))
    (if* (string= type "void")
       then "void"
     elseif (char= #\* (rpcgen-peekchar stream))
       then (rpcgen-lex stream #\*)
	    (generate-optional-func type)
	    (let ((name (lispify-string (rpcgen-lex stream :word))))
	      (values (concatenate 'string "optional-" type)
		      name))
       else (let ((name (lispify-string (rpcgen-lex stream :word)))
		  (char (rpcgen-peekchar stream))
		  variable-fixed len)
	      (if* (or (eq char #\[) (eq char #\<))
		 then (rpcgen-lex stream char)
		      
		      (if* (and (char= char #\<) 
				(eq (rpcgen-peekchar stream) #\>))
			 then (setf len nil)
			 else (setf len 
				(constantify-string (rpcgen-lex stream :word))))
		      (ecase char
			(#\[
			 (setf char #\])
			 (setf variable-fixed :fixed))
			(#\<
			 (setf char #\>)
			 (setf variable-fixed :variable)))
		      (rpcgen-lex stream char))
	      
	      (when (string= type "string")
		(if (eq variable-fixed :fixed)
		    (error "string ~a[~a]: Ambigious.  Fixed size string or array of strings? Aborting" name len))
		(setf variable-fixed nil))
		      
	      (values type name variable-fixed len)))))

(defun rpcgen-program (stream)
  (let (prgname prognum vers-defs)
    
    (setf prgname (constantify-string (rpcgen-lex stream :word)))
    
    (rpcgen-lex stream #\{)
    
    (while (not (eq (rpcgen-peekchar stream) #\}))
      (push (rpcgen-version stream) vers-defs))
    
    (rpcgen-lex stream #\})
    (rpcgen-lex stream #\=)
    
    (setf prognum (parse-integer (rpcgen-lex stream :word)))
    (rpcgen-lex stream #\;)
    
    (setf vers-defs (nreverse vers-defs))
  
    (make-program :name prgname :number prognum :versions vers-defs)))
    
;; returns a list of vers-const, versnum, list-of-funcs
(defun rpcgen-version (stream)
  (let (vers-const funcs versnum)
    
    (if (not (equalp (rpcgen-lex stream :word) "version"))
	(error "Syntax error: Expected 'version'"))
    
    (setf vers-const (constantify-string (rpcgen-lex stream :word)))
    
    (rpcgen-lex stream #\{)

    (while (not (eq (rpcgen-peekchar stream) #\}))
      (push (rpcgen-function stream) funcs))
    
    (rpcgen-lex stream #\})
    (rpcgen-lex stream #\=)
    (setf versnum (parse-integer (rpcgen-lex stream :word)))
    (rpcgen-lex stream #\;)

    (make-program-version :name vers-const
			  :number versnum
			  :procedures (nreverse funcs))))


;; Returns list of the name, procnum, arg type, and return type
(defun rpcgen-function (stream)
  (let ((ret-type (rpcgen-parse-type stream))
	(func-name (lispify-string (rpcgen-lex stream :word)))
	arg-type procnum)
    (rpcgen-lex stream #\()
    
    (setf arg-type (rpcgen-parse-type stream))
    
    (rpcgen-lex stream #\))
    (rpcgen-lex stream #\=)
    
    (setf procnum (parse-integer (rpcgen-lex stream :word)))
    
    (rpcgen-lex stream #\;)
    
    (make-procedure :name func-name :number procnum
		    :arg-type arg-type :return-type ret-type)))

(defun lispify-string (string)
  (string-downcase (substitute #\- #\_ string)))

(defun constantify-string (string)
  (if (ignore-errors (parse-integer string))
      string
    (concatenate 'string "*" (lispify-string string) "*")))