;; -*- mode: common-lisp -*-
;;
;; Copyright (C) 2001 Franz Inc, Berkeley, CA.  All rights reserved.
;;
;; This code is free software; you can redistribute it and/or
;; modify it under the terms of the version 2.1 of
;; the GNU Lesser General Public License as published by 
;; the Free Software Foundation, as clarified by the Franz
;; preamble to the LGPL found in
;; http://opensource.franz.com/preamble.html.
;;
;; This code is distributed in the hope that it will be useful,
;; but without any warranty; without even the implied warranty of
;; merchantability or fitness for a particular purpose.  See the GNU
;; Lesser General Public License for more details.
;;
;; Version 2.1 of the GNU Lesser General Public License can be
;; found at http://opensource.franz.com/license.html.
;; If it is not present, you can access it from
;; http://www.gnu.org/copyleft/lesser.txt (until superseded by a newer
;; version) or write to the Free Software Foundation, Inc., 59 Temple
;; Place, Suite 330, Boston, MA  02111-1307  USA
;;
;; $Id: sunrpc.cl,v 1.13 2001/08/15 23:35:15 dancy Exp $

(in-package :user)

(eval-when (compile)
  (declaim (optimize (speed 3) (safety 1))))

(defstruct rpc-peer
  type
  socket
  addr
  port
  )

(defstruct rpc-server
  tcpsock
  udpsock
  tcpclientlist)

(defparameter *rpcgetmessagebuf* (make-array 65536 :element-type '(unsigned-byte 8)))

;; returns an xdr
(defun rpc-get-message (server)
  (symbol-macrolet ((clientlist (rpc-server-tcpclientlist server)))
    (let ((tcpsock (rpc-server-tcpsock server))
	  (udpsock (rpc-server-udpsock server))
	  waitlist
	  readylist
	  record)
      (loop
	(setf waitlist clientlist)
	(when tcpsock
	  (push tcpsock waitlist))
	(when udpsock
	  (push udpsock waitlist))
	;;(format t "waiting for input.~%")
	;;(format t "waitlist is ~S~%" waitlist)
	(handler-case (setf readylist (mp:wait-for-input-available waitlist))
	  (socket-error (c)
	    (case (stream-error-identifier c)
	      (:connection-reset 
	       (let ((stream (stream-error-stream c)))
		 (format t "closing error socket ~S~%" stream)
		 (close stream)
		 (setf clientlist (remove stream clientlist))
		 nil))
	      (t 
	       (error c)))))
		 
	;;(format t "readylist is ~A~%" readylist)
	
	(when (member tcpsock readylist)
	  (format t "Accepting new tcp connection and adding it to the client list.~%")
	  (push (socket:accept-connection tcpsock) clientlist)
	  (setf readylist (remove tcpsock readylist)))
	
	(when (member udpsock readylist)
	  (multiple-value-bind (vec count addr port)
	      (handler-case (socket:receive-from udpsock 65536 :buffer *rpcgetmessagebuf*)
		(socket-error (c) 
		  (format t "Ignoring error condition ~S~%" c)
		  nil))
	    (unless (null vec)
	      (return-from rpc-get-message
		(values (create-xdr :vec vec :size count)
			(make-rpc-peer :type :datagram :socket udpsock
				       :addr addr :port port))))
	    (setf readylist (remove udpsock readylist))))
	
                  ;;; all remaining entries on readylist will be tcp clients
	(dolist (s readylist)
	  (setf record (read-record s))
	  (if (null record)
	      (progn
		(format t "Client ~s disconnected.~%" s)
		(close s)
		(setf clientlist (remove s clientlist))
		)
	    (return-from rpc-get-message 
	      (values (create-xdr :vec record)
		      (make-rpc-peer :type :stream :socket s)
		      ))))))))
  
  
(defun read-int-from-stream (stream)
  (let* ((vec (make-array 4 :element-type '(unsigned-byte 8)))
         (res (read-sequence vec stream)))
    (if (= res 0)        
        (return-from read-int-from-stream nil));; indicate EOF
    (let ((xdr (create-xdr :vec vec)))
      (xdr-int xdr))))


(defun read-record (stream)
  (handler-case 
      (let ((size (read-int-from-stream stream)))
	(if (null size)
	    (return-from read-record nil)) ;; indicate EOF
	(when (= (logand size #x80000000) 0)
	  (error "read-record: Fragments aren't handled yet"))
	(setf size (logand size #x7fffffff))
	;;(format t "Message is ~d bytes~%" size)
	(let* ((buffer (make-array size :element-type '(unsigned-byte 8)))
	       (res (read-sequence buffer stream)))
	  (unless (= res size)
	    (error "read-record: read-sequence only returned ~D bytes" res))
	  buffer))
    (t (c)
      (format t "read-record got error ~A~%Returning nil~%" c)
      nil)))

(defstruct rpc-msg 
  xid
  mtype ;; CALL = 0, REPLY = 1
  cbody ;; (for CALL)
  rbody ;; (for REPLY)
  )

(defun create-rpc-msg (xdr)
  (let* ((msg (make-rpc-msg))
         (xid (xdr-int xdr))
         (mtype (xdr-int xdr)))
    (setf (rpc-msg-xid msg) xid)
    (setf (rpc-msg-mtype msg) mtype)
    (cond
     ((= mtype 0) ;; CALL
      (setf (rpc-msg-cbody msg) (create-call-body xdr)))
     #|
     ((= mtype 1) ;; REPLY
     (setf (rpc-msg-rbody msg) (create-reply-bodyxdr)))
     |#
     (t
      (error "read-rpc-msg: Unknown mtype ~D" mtype)))
    msg))

(defstruct call-body
  rpcvers
  prog
  vers
  proc
  cred
  verf
  params
  )

(defun create-call-body (xdr)
  (let ((cbody (make-call-body)))
    (setf (call-body-rpcvers cbody) (xdr-int xdr))
    (unless (= 2 (call-body-rpcvers cbody))
      (error "create-call-body: Unsupported RPC Version requested: ~D~%" (call-body-rpcvers cbody)))
    (setf (call-body-prog cbody) (xdr-int xdr))
    (setf (call-body-vers cbody) (xdr-int xdr))
    (setf (call-body-proc cbody) (xdr-int xdr))
    ;;(format t "create-call-body: Getting credentials~%")
    (setf (call-body-cred cbody) (xdr-opaque-auth xdr))
    ;;(format t "create-call-body: Getting verifier~%")
    (setf (call-body-verf cbody) (xdr-opaque-auth xdr))
    (setf (call-body-params cbody) (xdr-xdr xdr))
    cbody))

(defun pprint-cbody (cbody)
  (format t "RPC Version: ~D~%" (call-body-rpcvers cbody))
  (format t "Program: ~D~%" (call-body-prog cbody))
  (format t "Program version: ~D~%" (call-body-vers cbody))
  (format t "Program procedure: ~D~%" (call-body-proc cbody))
  ;;(format t "Cred: ~S~%" (call-body-cred cbody))
  ;;(format t "Verf: ~S~%" (call-body-verf cbody))
  )
  
  
(defstruct reply-body
  stat ;; MSG_ACCEPTED = 0, MSG_DENIED = 1
  areply ;; (for MSG_ACCEPTED)
  rreply ;; (for MSG_DENIED)
  )

(defstruct accepted-reply
  verf 
  stat ;; SUCCESS = 0, PROG_UNAVAIL = 1, PROG_MISMATCH = 2, PROC_UNAVAIL = 3, GARBAGE_ARGS = 4
  results ;; (for SUCCESS)
  mismatch-info ;; (for PROG_MISMATCH)
  )

(defstruct mismatch-info
  lwo
  high)

(defstruct rejected-reply
  reject-stat ;; RPC_MISMATCH = 0, AUTH_ERROR = 1
  mismatch-info ;; (for RPC_MISMATCH)
  auth-stat ;; (for AUTH_ERROR)
  )

(defparameter *gather* t) ;; easier to use network analyzers w/ this on.

(defun rpc-send (xdr peer)
  (let ((type (rpc-peer-type peer)))
    (cond
     ((eq type :stream)
      (if *gather*
	  (progn
	    (let ((newxdr (create-xdr :direction :build :size (+ 4 (xdr-size xdr)))))
	      (xdr-int newxdr (logior #x80000000 (xdr-size xdr)))
	      (xdr-xdr newxdr xdr) ;; slow
	      (ignore-errors (write-sequence (xdr-get-complete-vec newxdr) (rpc-peer-socket peer) :end (xdr-size newxdr)))))
      (let ((sizexdr (create-xdr :direction :build :size 4)))
        (xdr-int sizexdr (logior #x80000000 (xdr-size xdr)))
	(ignore-errors
	 (write-sequence (xdr-get-complete-vec sizexdr) (rpc-peer-socket peer))
	 (write-sequence (xdr-get-complete-vec xdr) (rpc-peer-socket peer) :end (xdr-size xdr))))))
     ((eq type :datagram)
      #-(version>= 6 1)
      (mp:wait-for-input-available (- 0 (socket::socket-fd (rpc-peer-socket peer)) 1))
      (ignore-errors (socket:send-to (rpc-peer-socket peer) 
				     (xdr-get-complete-vec xdr) 
				     (xdr-size xdr) 
				     :remote-host (rpc-peer-addr peer)
				     :remote-port (rpc-peer-port peer)))))))

(defun rpc-send-reply (peer xid rbody)  ;; rbody should be an xdr
  (let ((xdr (create-xdr :direction :build)))
    (xdr-int xdr xid)
    (xdr-int xdr 1) ;; REPLY
    (xdr-xdr xdr rbody)
    (rpc-send xdr peer)))
    
(defun send-accepted-reply (peer xid verf stat reply)
  (let ((xdr (create-xdr :direction :build)))
    (xdr-int xdr xid)
    (xdr-int xdr 1) ;; REPLY
    (xdr-int xdr 0) ;; MSG_ACCEPTED
    (xdr-xdr xdr verf) 
    (xdr-int xdr stat) 
    (xdr-xdr xdr reply)
    (rpc-send xdr peer)))

(defun send-successful-reply (peer xid verf results)
  (send-accepted-reply peer xid verf 0 results))

(defmacro with-successful-reply ((xdr-name peer xid verf &key (create t)) &body body)
  `(let ((,xdr-name (if ,create (create-xdr :direction :build)  
		      (progn
			(xdr-flush ,xdr-name)
			,xdr-name))))
     (xdr-int ,xdr-name ,xid)
     (xdr-int ,xdr-name 1) ;; REPLY
     (xdr-int ,xdr-name 0) ;; MSG_ACCEPTED
     (xdr-xdr ,xdr-name ,verf) 
     (xdr-int ,xdr-name 0) ;; SUCCESS
     ,@body
     (rpc-send ,xdr-name ,peer)))



(defun rpc-send-rejected-reply (peer xid rreply)
  (let ((xdr (create-xdr :direction :build)))
    (xdr-int xdr 1) ;; MSG_DENIED
    (xdr-xdr xdr rreply)
    (rpc-send-reply peer xid xdr)))

(defun rpc-send-auth-error-rejected-reply (peer xid stat)
  (let ((xdr (create-xdr :direction :build)))
    (xdr-int xdr 1) ;; AUTH_ERROR
    (xdr-int xdr stat) ;; auth_stat
    (rpc-send-rejected-reply peer xid xdr)))

(defun rpc-send-prog-unavail (peer xid verf)
  (let ((xdr (create-xdr :direction :build)))
    (send-accepted-reply peer xid verf 1 xdr)))

(defun rpc-send-proc-unavail (peer xid verf)
  (let ((xdr (create-xdr :direction :build)))
    (send-accepted-reply peer xid verf 3 xdr)))

(defun rpc-send-prog-mismatch (peer xid verf lowest highest)
  (let ((xdr (create-xdr :direction :build)))
    (xdr-unsigned-int xdr lowest)
    (xdr-unsigned-int xdr highest)
    (send-accepted-reply peer xid verf 2 xdr)))
  
