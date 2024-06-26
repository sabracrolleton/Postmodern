;;;; -*- Mode: LISP; Syntax: Ansi-Common-Lisp; Base: 10; Package: CL-POSTGRES-TRIVIAL-UTF-8; -*-

;;; Minimal utf-8 decoding and encoding library.
;;;
;;; See http://common-lisp.net/project/trivial-utf-8/ (no longer maintained?)
;;; This file is being kept in case we need to make patches or additions

(in-package :cl-postgres-trivial-utf-8)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *optimize*
    '(optimize
      (speed 3)
      #-ecl(safety 0) #+ecl(safety 1)
      (space 0)
      (debug 1)
      (compilation-speed 0))))

(defun utf-8-byte-length (string)
  "Calculate the amount of bytes needed to encode a string."
  (declare (type string string)
           #'*optimize*)
  (let ((length (length string))
        (string (coerce string 'simple-string)))
    (loop :for char :across string
          :do (let ((code (char-code char)))
                (when (> code 127)
                  (incf length
                        (cond ((< code 2048) 1)
                              ((< code 65536) 2)
                              (t 3))))))
    length))

(defmacro as-utf-8-bytes (char writer)
  "Given a character, calls the writer function for every byte in the
encoded form of that character."
  (let ((char-code (gensym)))
    `(let ((,char-code (char-code ,char)))
       (declare (type fixnum ,char-code))
       (cond ((< ,char-code 128)
              (,writer ,char-code))
             ((< ,char-code 2048)
              (,writer (logior #b11000000 (ldb (byte 5 6) ,char-code)))
              (,writer (logior #b10000000 (ldb (byte 6 0) ,char-code))))
             ((< ,char-code 65536)
              (,writer (logior #b11100000 (ldb (byte 4 12) ,char-code)))
              (,writer (logior #b10000000 (ldb (byte 6 6) ,char-code)))
              (,writer (logior #b10000000 (ldb (byte 6 0) ,char-code))))
             (t
              (,writer (logior #b11110000 (ldb (byte 3 18) ,char-code)))
              (,writer (logior #b10000000 (ldb (byte 6 12) ,char-code)))
              (,writer (logior #b10000000 (ldb (byte 6 6) ,char-code)))
              (,writer (logior #b10000000 (ldb (byte 6 0) ,char-code))))))))

(defun string-to-utf-8-bytes (string &key null-terminate)
  "Convert a string into an array of unsigned bytes containing its
utf-8 representation. If NULL-TERMINATE, add an extra 0 byte at the end."
  (declare (type string string)
           #.*optimize*)
  (let ((buffer (make-array (+ (the fixnum (utf-8-byte-length string))
                               (if null-terminate 1 0))
                            :element-type '(unsigned-byte 8)
                            :initial-element 0))
        (position 0)
        (string (coerce string 'simple-string)))
    (declare (type (array (unsigned-byte 8)) buffer)
             (type fixnum position))
    (macrolet ((add-byte (byte)
                 `(progn (setf (aref buffer position) ,byte)
                         (incf position))))
      (loop :for char :across string
            :do (as-utf-8-bytes char add-byte)))
    (when null-terminate
      (setf (elt buffer (1- (length buffer))) 0))
    buffer))

(defun write-utf-8-bytes (string output &key null-terminate)
  "Write a string to a byte-stream, encoding it as utf-8."
  (declare (type string string)
           (type stream output)
           #.*optimize*)
  (macrolet ((byte-out (byte)
               `(write-byte ,byte output)))
    (let ((string (coerce string 'simple-string)))
      (loop :for char :across string
            :do (as-utf-8-bytes char byte-out))))
  (when null-terminate
    (write-byte 0 output)))

(define-condition utf-8-decoding-error (simple-error)
  ((message :initarg :message)
   (byte :initarg :byte :initform nil))
  (:report (lambda (err stream)
             (format stream (slot-value err 'message)
                     (slot-value err 'byte)))))

(declaim (inline utf-8-group-size))
(defun utf-8-group-size (byte)
  "Determine the amount of bytes that are part of the character
starting with a given byte."
  (declare (type fixnum byte)
           #.*optimize*)
  (cond ((zerop (logand byte #b10000000)) 1)
        ((= (logand byte #b11100000) #b11000000) 2)
        ((= (logand byte #b11110000) #b11100000) 3)
        ((= (logand byte #b11111000) #b11110000) 4)
        (t (error 'utf-8-decoding-error :byte byte
                  :message "UTF-8-group-size Invalid byte at start of character: 0x~X"))))

(defun utf-8-string-length (bytes &key (start 0) (end (length bytes)))
  "Calculate the length of the string encoded by the given bytes."
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes)
           (type fixnum start end)
           #.*optimize*)
  (loop :with i :of-type fixnum = start
        :with string-length = 0
        :while (< i end)
        :do (progn
              (incf (the fixnum string-length) 1)
              (incf i (utf-8-group-size (elt bytes i))))
        :finally (return string-length)))

(defun get-utf-8-character (bytes group-size &optional (start 0))
  "Given an array of bytes and the amount of bytes to use,
extract the character starting at the given start position."
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes)
           (type fixnum group-size start)
           #.*optimize*)
  (labels ((next-byte ()
             (prog1 (elt bytes start)
               (incf start)))
           (six-bits (byte)
             (unless (= (logand byte #b11000000) #b10000000)
               (error 'utf-8-decoding-error :byte byte
                      :message
                      "Get-utf-8-character Invalid byte 0x~X inside a character."))
             (ldb (byte 6 0) byte)))
    (case group-size
      (1 (next-byte))
      (2 (logior (ash (ldb (byte 5 0) (next-byte)) 6)
                 (six-bits (next-byte))))
      (3 (logior (ash (ldb (byte 4 0) (next-byte)) 12)
                 (ash (six-bits (next-byte)) 6)
                 (six-bits (next-byte))))
      (4 (logior (ash (ldb (byte 3 0) (next-byte)) 18)
                 (ash (six-bits (next-byte)) 12)
                 (ash (six-bits (next-byte)) 6)
                 (six-bits (next-byte)))))))

(defun utf-8-bytes-to-string (bytes-in &key (start 0) (end (length bytes-in)))
  "Convert a byte array containing utf-8 encoded characters into
the string it encodes."
  (declare (type vector bytes-in)
           (type fixnum start end)
           #.*optimize*)
  (loop :with bytes = (coerce bytes-in '(simple-array (unsigned-byte 8) (*)))
        :with buffer = (make-string (utf-8-string-length bytes :start start :end end) :element-type 'character)
        :with array-position :of-type fixnum = start
        :with string-position :of-type fixnum = 0
        :while (< array-position end)
        :do
           (let* ((char (elt bytes array-position))
                  (current-group (utf-8-group-size char)))
             (when (> (+ current-group array-position) end)
               (error 'utf-8-decoding-error
                      :message
                      "utf-8-bytes-to-string. Unfinished character at end of byte array."))
             (setf (char buffer string-position)
                   (code-char (get-utf-8-character bytes current-group
                                                   array-position)))
             (incf string-position 1)
             (incf array-position current-group))
        :finally (return buffer)))

(defun read-utf-8-string (input &key null-terminated stop-at-eof
                          (char-length -1) (byte-length -1))
  "Read utf-8 encoded data from a byte stream and construct a
string with the characters found. When null-terminated is given
it will stop reading at a null character, stop-at-eof tells it to
stop at the end of file without raising an error, and the
char-length and byte-length parameters can be used to specify the
max amount of characters or bytes to read."
  (declare (type stream input)
           (type fixnum byte-length char-length)
           #.*optimize*)
  (let ((buffer (make-array 4
                            :element-type '(unsigned-byte 8)
                            :initial-element 0))
        (bytes-read 0)
        (string (make-array 64 :element-type 'character
                            :adjustable t :fill-pointer 0)))
    (declare (type fixnum bytes-read))
    (loop
       (when (or (and (/= -1 byte-length) (>= bytes-read byte-length))
		 (and (/= -1 char-length) (= char-length (length string))))
	 (return))
       (let ((next-char (read-byte input (not stop-at-eof) :eof)))
	 (when (or (eq next-char :eof)
		   (and null-terminated (eq next-char 0)))
	   (return))
	 (let ((current-group (utf-8-group-size next-char)))
	   (incf bytes-read current-group)
	   (cond ((= current-group 1)
		  (vector-push-extend (code-char next-char) string))
		 (t
		  (setf (elt buffer 0) next-char)
		  (loop :for i :from 1 :below current-group
		     :for next-char = (read-byte input nil :eof)
		     :do (when (eq next-char :eof)
			   (error 'utf-8-decoding-error
				  :message "read-utf-8-string. Unfinished character at end of input."))
		     :do (setf (elt buffer i) next-char))
		  (vector-push-extend (code-char (get-utf-8-character
						  buffer current-group))
				      string))))))
    string))
