(in-package :user)

;; $Id: rpcgen.cl,v 1.9 2008/01/04 19:03:55 dancy Exp $

(eval-when (compile load eval)
  (require :osi))

(defmacro with-input-from-subprocess ((cmd var) &body body)
  `(multiple-value-bind (,var dummy pid)
       (run-shell-command ,cmd :output :stream :wait nil
			  :show-window :hide)
     (declare (ignore dummy))
     (unwind-protect
	 (progn ,@body)
       (close ,var)
       (sys:reap-os-subprocess :pid pid))))


(defparameter *unread-buffer* nil)
(defparameter *optionals* nil)
(defparameter *unions* nil)
(defparameter *structs* nil)

(defstruct enum
  name
  values)

(defstruct struct
  name
  members
  optional)

(defstruct xunion
  name
  members
  optional
  discrimtype
  discrimname)

;; union or struct member
(defstruct struct-member 
  type 
  name
  fixed
  len
  cases) ;; unions only
  
(defstruct typedef
  type
  name
  len ;; if fixed
  optional)

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
  
(defparameter *header* ";; Do not edit this file.  It was automatically generated by rpcgen.cl

(eval-when (compile)
  (declaim (optimize speed)))
")

(defun rpcgen (filename &key out-base)
  (let (programs constants enums typedefs)
    ;; Generate an error message if the file doesn't exist.
    (close (open filename))

    (if (null out-base)
	(setf out-base (pathname-name filename)))
    
    (setf *optionals* nil)
    (setf *unread-buffer* nil)
    (setf *unions* nil)
    (setf *structs* nil)
  
    (with-input-from-subprocess
	((format nil "bash -c 'cpp ~a | grep -v ^#'" filename)
	 stream)
    
      (while (rpcgen-peekchar stream)
	(let ((token (rpcgen-lex stream :word)))
	  (cond
	   ((string= token "const")
	    (push (rpcgen-const stream) constants))
	   ((string= token "enum")
	    (push (rpcgen-enum stream) enums))
	   ((string= token "typedef")
	    (let ((res (rpcgen-typedef stream)))
	      (if res 
		  (push res typedefs))))
	   ((string= token "struct")
	    (let ((res (rpcgen-struct stream)))
	      (if (not (struct-p res))
		  (error "Syntax error near 'struct ~a'" res))
	      (if (null (struct-name res))
		  (error "Anonymous structs are not allowed on the top level"))))
	   ((string= token "union")
	    (push (rpcgen-union stream) *unions*))
	   ((string= token "program")
	    (push (rpcgen-program stream) programs))
	   (t
	    (error "Unexpected token: ~a" token)))
	  (rpcgen-lex stream #\;))))

    (setf programs (nreverse programs))
    (setf constants (nreverse constants))
    (setf enums (nreverse enums))
    (setf typedefs (nreverse typedefs))
    (setf *structs* (nreverse *structs*))
    (setf *unions* (nreverse *unions*))

    (with-open-file (f 
		     (concatenate 'string out-base "-common.cl")
		     :direction :output
		     :if-exists :supersede)

      (write-line *header* f)
      
      (format f "(defpackage :~a~%  (:use :lisp :excl :xdr)~%  (:export~%"
	      out-base)
      (dolist (const constants)
	(format f "   #:~a~%" (first const)))
      (dolist (enum enums)
	(format f "   #:~a~%" (enum-name enum))
	(format f "   #:xdr-~a~%" (enum-name enum))
	(dolist (pair (enum-values enum))
	  (format f "   #:~a~%" (car pair))))
      (dolist (td typedefs)
	(format f "   #:xdr-~a~%" (typedef-name td)))
      (dolist (program programs)
	(format f "   #:~a~%" (program-name program))
	(dolist (version (program-versions program))
	  (format f "   #:~a~%" (program-version-name version))
	  (dolist (proc (program-version-procedures version))
	    (format f "   #:~a~%" (procedure-name proc))
	    (format f "   #:call-~a-~a~%"
		    (string-downcase (procedure-name proc))
		    (program-version-number version)))))
      (format f "  ))~%")
      (format f ";; Other struct/union makers/accessors are automatically exported as well.~%~%")
      (format f "~%(in-package :~a)~%~%" out-base)

      (when constants
	(format f ";; Constants~%(eval-when (compile load eval)~%")
	(dolist (const constants)
	  (multiple-value-bind (varname value)
	      (values-list const)
	    (format f "(defconstant ~a ~a)~%" varname value)))
	(format f ")~%~%"))

      (when enums
	(format f ";; Enums~%(eval-when (compile load eval)~%")
	(dolist (enum enums)
	  (format f ";; enum ~a~%" (enum-name enum))
	  (dolist (pair (enum-values enum))
	    (format f "(defconstant ~a ~a)~%" (car pair) (cdr pair)))
	  (format f "~%"))
	(format f ")~%~%"))

      (format f ";; Structs~%~%")
      (dolist (struct *structs*)
	(let ((first t)
	      (indent 
	       (make-string (+ (length (struct-name struct)) 16)
			    :initial-element #\space)))
	  (format f "(defxdrstruct ")
	  (if* (struct-optional struct)
	     then (format f "(~a :optional)" (struct-name struct))
	     else (write-string (struct-name struct) f))
	  (format f " (")
	  (dolist (member (struct-members struct))
	    (if* first
	       then (setf first nil)
	       else (format f "~%~a" indent))
	  
	    (format f "(~a ~a" 
		    (get-type-name (struct-member-type member))
		    (struct-member-name member))
	    (if (struct-member-fixed member)
		(format f " ~s ~a" 
			(struct-member-fixed member)
			(struct-member-len member)))

	    (format f ")"))
	  
	  (format f "))~%~%")))
    
      (format f ";; Unions~%~%")
      (dolist (union *unions*)
	(format f "(defxdrunion ~a (~a ~a)~% (~%" 
		(xunion-name union) (xunion-discrimtype union)
		(xunion-discrimname union))
	(dolist (member (xunion-members union))
	  (let ((cases (struct-member-cases member)))
	    (if* (eq cases :default)
	       then (format f "  (:default ")
	     elseif (= (length cases) 1)
	       then (format f "  (~a " (first cases))
	       else (format f "  (~a " cases))
	    (format f "~a ~a)~%" 
		    (get-type-name (struct-member-type member))
		    (struct-member-name member))))
	(format f " ))~%~%"))
    
      (format f ";; Typedefs~%~%")
      (dolist (enum enums)
	(format f "(defun xdr-~a (xdr &optional int)~% (xdr-int xdr int))~%~%"
		(enum-name enum)))

      (dolist (td typedefs)
	(if* (typedef-len td)
	   then (format f "(defun xdr-~a (xdr &optional arg)~%  (xdr-array-fixed xdr #'xdr-~a :things arg :len #.~a))~%~%" 
			(typedef-name td) (typedef-type td) (typedef-len td))
	 elseif (typedef-optional td)
	   then (format f "(defun xdr-~a (xdr &optional data)~%  (xdr-optional xdr #'xdr-~a data))~%~%" 
			(typedef-name td) (typedef-type td))
	   else (format f "(defun xdr-~a (xdr &optional data)~%  (xdr-~a xdr data))~%~%" 
			(typedef-name td) (typedef-type td))))
    
      (format f ";; Helpers~%~%")
      (dolist (opt *optionals*)
	(format f "(defun xdr-optional-~a (xdr &optional arg)~%  (xdr-optional xdr #'xdr-~a arg))~%~%" opt opt))

      (format f ";; Programs~%~%(eval-when (compile load eval)~%")
      (let (seen-constants)
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
	      (if* (not (member (procedure-name proc) seen-constants
				:test #'equal))
		 then (push (procedure-name proc) seen-constants)
		      (format f " (defconstant ~a ~d)~%" 
			      (procedure-name proc)
			      (procedure-number proc))))
	    (format f "~%"))))
      (format f ") ;; eval-when~%~%"))

    (when programs
      (with-open-file (f 
		       (concatenate 'string out-base "-server.cl")
		       :direction :output
		       :if-exists :supersede)
      
	(write-line *header* f)
	
	(format f "(in-package :~a)~%~%" out-base)
      
	(dolist (program programs)
	  (format f "(sunrpc:def-rpc-program (~a ~a)~%" 
		  out-base (program-number program))
	  (format f "  (~%")
	  (dolist (version (program-versions program))
	    (format f "   (~a ;; version~%" (program-version-number version))
	    (dolist (proc (program-version-procedures version))
	      (format f "     (~a ~a ~a ~a)~%" 
		      (procedure-number proc)
		      (string-downcase (procedure-name proc))
		      (procedure-arg-type proc)
		      (procedure-return-type proc)))
	    (format f "   )~%"))
	  (format f "  ))~%")))
    
      (with-open-file (f 
		       (concatenate 'string out-base "-client.cl")
		       :direction :output
		       :if-exists :supersede)
      
	(write-line *header* f)

	(format f "(in-package :~a)~%~%" out-base)
	
	(dolist (program programs)
	  (dolist (version (program-versions program))
	    (dolist (proc (program-version-procedures version))
	      (format f "~
(defun call-~a-~a (cli arg &key (retries 3) (timeout 5) no-reply)
  (sunrpc:callrpc cli ~a #'xdr-~a arg 
		  :outproc #'xdr-~a
		  :retries retries
		  :timeout timeout
		  :no-reply no-reply))~%~%"
		      (string-downcase (procedure-name proc))
		      (program-version-number version)
		      (procedure-number proc)
		      (procedure-arg-type proc)
		      (procedure-return-type proc)))))))))

(defun get-type-name (thing)
  (if* (complex-type-p thing)
     then (struct-name thing)
     else thing))

(defun rpcgen-unread (thing)
  (if *unread-buffer*
      (error "unread buffer is already used"))
  (setf *unread-buffer* thing))

(defun rpcgen-lex-1 (stream)
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
	    
	    (make-array (length res) :element-type 'character
			:initial-contents (nreverse res))
       else ;; EOF or special character.  Return it.
	    char)))

(defun rpcgen-peek (stream)
  (if* *unread-buffer*
     then *unread-buffer*
     else (setf *unread-buffer* (rpcgen-lex-1 stream))))

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

;; Deprecated.  rpcgen-peek is better.
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
    (if* (string= string "0")
       then string
     elseif (prefixp "0x" string)
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
      
      `(,varname ,value))))
      
(defun rpcgen-typedef (stream)
  (multiple-value-bind (type name varfixed len)
      (rpcgen-parse-type-and-name stream)

    ;; Ignore attempts to override some implicit typedefs.
    (when (not (member name '("uint32" "uint64") :test #'equalp))
      (make-typedef :type type
		    :name name
		    :len (if (eq :fixed varfixed) len)))))

    
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
    
    (make-enum :name typename :values (nreverse values))))

;; struct type         /* reference */
;; struct type { ... }  /* named definition */
;; struct { ... }       /* Anonymous definition */

(defun rpcgen-struct (stream)
  (let (typename members)
    (if (stringp (rpcgen-peek stream))
	(setf typename (lispify-string (rpcgen-lex stream :word))))
    
    (if* (eq (rpcgen-peek stream) #\{)
       then ;; definition
	    (rpcgen-lex stream #\{)
	    (while (not (eq (rpcgen-peekchar stream) #\}))
	      (multiple-value-bind (type name fixed len)
		  (rpcgen-parse-type-and-name stream)
		(push (make-struct-member :type type
					  :name name
					  :fixed fixed
					  :len len) 
		      members))
	      (rpcgen-lex stream #\;))
	    
	    (rpcgen-lex stream #\})
	    
	    (let ((res 
		   (finalize-anonymous-types
		    (make-struct :name typename :members (nreverse members)))))
	      (push res *structs*)
	      res)
	      
       else ;; reference
	    (if (null typename)
		(error "Syntax error near 'struct'"))
	    typename)))
	    
    
(defun rpcgen-union (stream)
  (let (typename current-cases members)
    
    (let ((tmp (lispify-string (rpcgen-lex stream :word))))
      (when (string/= tmp "switch")
	(setf typename tmp)
	(if (string/= (rpcgen-lex stream :word) "switch")
	    (error "Syntax error: Expected 'switch'"))))

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
		(multiple-value-bind (type name fixed len)
		    (rpcgen-parse-type-and-name stream)
		  (rpcgen-lex stream #\;)
		  (push (make-struct-member :cases (nreverse current-cases)
					    :type type
					    :name name
					    :fixed fixed
					    :len len)
			members)
		  (setf current-cases nil)))))
	   ((string= token "default")
	    (rpcgen-lex stream #\:)
	    (multiple-value-bind (type name fixed len)
		(rpcgen-parse-type-and-name stream)
	      (rpcgen-lex stream #\;)
	      
	      (push (make-struct-member :cases :default
					:type type
					:name name
					:fixed fixed
					:len len)
		    members)))
	   (t
	    (error "Unexpected word: ~a" token)))))
      
      (rpcgen-lex stream #\})

      (finalize-anonymous-types
       (make-xunion :name typename 
		    :discrimtype discrimtype
		    :discrimname discrimname
		    :members (nreverse members))))))

(defun complex-type-p (thing)
  (or (struct-p thing) (xunion-p thing)))

(defun finalize-anonymous-types (thing)
  (when (struct-name thing)
    (dolist (member (struct-members thing))
      (let ((type (struct-member-type member)))
	(when (and (complex-type-p type) (null (struct-name type)))
	  ;; Set the name based on our name and the slot name.
	  (setf (struct-name type)
	    (concatenate 'string (struct-name thing) "-" 
			 (struct-member-name member) "-"
			 (if (struct-p type) "s" "u")))
	  (if (struct-optional type)
	      (generate-optional-func (struct-name type)))
	  (finalize-anonymous-types type)))))
  thing)

(defun rpcgen-parse-type-1 (stream)
  (block nil
    (let ((type (rpcgen-lex stream :word)))

      (when (string= type "unsigned")
	(let ((next (rpcgen-peek stream)))
	  (when (or (equal next "int")
		    (equal next "long"))
	    (rpcgen-lex stream :word)
	    (return "unsigned-int")))

	(when (equal (rpcgen-peek stream) "hyper")
	  (rpcgen-lex stream :word)
	  (return "unsigned-hyper"))
	
	(return "unsigned-int"))
      
      (if (or (equal type "u_int64_t") (equal type "uint64"))
	  (return "unsigned-hyper"))
      (if (or (equal type "u_int32_t") (equal type "uint32"))
	  (return "unsigned-int"))
      (if (equal type "long")
	  (return "int"))
      
      (when (string= type "union")
	(let ((u (rpcgen-union stream)))
	  (push u *unions*)
	  (return u)))
    
      (when (string= type "struct")
	(return (rpcgen-struct stream)))
    
      (lispify-string type))))

(defun rpcgen-parse-type (stream)
  (let ((type (rpcgen-parse-type-1 stream))
	optional)
    (if* (eq (rpcgen-peek stream) #\*)
       then (rpcgen-lex stream #\*)
	    (setf optional t))
    
    (values type optional)))

(defun generate-optional-func (type)
  (pushnew type *optionals* :test #'string=))

;; returns values:
;;  type, name, variable/fixed, length
(defun rpcgen-parse-type-and-name (stream)
  (block nil
    (multiple-value-bind (type optional)
	(rpcgen-parse-type stream)
      (if* (equal type "void")
	 then (return "void"))
      
      (when optional
	(if* (and (struct-p type) (null (struct-name type)))
	   then (setf (struct-optional type) t)
	   else (generate-optional-func type)
		(setf type (concatenate 'string "optional-" type))))

      (let ((name (lispify-string (rpcgen-lex stream :word)))
	    (char (rpcgen-peekchar stream))
	    variable-fixed len)
	
	(if* (or (eq char #\[) (eq char #\<))
	   then 
		(rpcgen-lex stream char)
		
		(if (and (equal type "string")
			 (not (char= char #\<)))
		    (error "Strings must be specified using <> syntax"))
		
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
		(rpcgen-lex stream char)
		
		;; Special cases.
		(when (and (equal type "opaque") (eq variable-fixed :variable))
		  (setf type "opaque-variable")
		  (setf variable-fixed nil))
		(if (equal type "string")
		    (setf variable-fixed nil))
	   else
		(if (equal type "string")
		    (error "string specified without <> or <size>")))
	
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
	(func-name (lispify-string (rpcgen-lex stream :word)
				   :no-downcase t))
	arg-type procnum)
    (rpcgen-lex stream #\()
    
    (setf arg-type (rpcgen-parse-type stream))
    
    (rpcgen-lex stream #\))
    (rpcgen-lex stream #\=)
    
    (setf procnum (parse-integer (rpcgen-lex stream :word)))
    
    (rpcgen-lex stream #\;)
    
    (make-procedure :name func-name :number procnum
		    :arg-type arg-type :return-type ret-type)))

(defun lispify-string (string &key no-downcase)
  (setf string (substitute #\- #\_ string))
  (if (not no-downcase)
      (setf string (string-downcase string)))
  string)

(defun constantify-string (string)
  (if (ignore-errors (parse-integer string))
      string
    (concatenate 'string "*" (lispify-string string) "*")))
