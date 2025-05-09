;;; test-ob-R.el --- tests for ob-R.el  -*- lexical-binding: t; -*-

;; Copyright (c) 2011-2014, 2019 Eric Schulte
;; Authors: Eric Schulte

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Code:
(org-test-for-executable "R")
(require 'ob-core)
(unless (featurep 'ess)
  (signal 'missing-test-dependency '("ESS")))
(defvar ess-ask-for-ess-directory)
(defvar ess-history-file)
(defvar ess-r-post-run-hook)
(declare-function
 ess-command "ext:ess-inf"
 (cmd &optional out-buffer sleep no-prompt-check wait proc proc force-redisplay timeout))
(declare-function ess-calculate-width "ext:ess-inf" (opt))

(unless (featurep 'ob-R)
  (signal 'missing-test-dependency '("Support for R code blocks")))

(ert-deftest test-ob-R/simple-session ()
  (let (ess-ask-for-ess-directory ess-history-file)
    (org-test-with-temp-text
     "#+begin_src R :session R\n  paste(\"Yep!\")\n#+end_src\n"
     (should (string= "Yep!" (org-babel-execute-src-block))))))

(ert-deftest test-ob-R/colnames-yes-header-argument ()
  (org-test-with-temp-text "#+name: eg
| col |
|-----|
| a   |
| b   |

#+header: :colnames yes
#+header: :var x = eg
#+begin_src R
x
#+end_src"
    (org-babel-next-src-block)
    (should (equal '(("col") hline ("a") ("b"))
		   (org-babel-execute-src-block)))))

(ert-deftest test-ob-R/colnames-nil-header-argument ()
  (org-test-with-temp-text "#+name: eg
| col |
|-----|
| a   |
| b   |

#+header: :colnames nil
#+header: :var x = eg
#+begin_src R
x
#+end_src"
    (org-babel-next-src-block)
    (should (equal '(("col") hline ("a") ("b"))
		   (org-babel-execute-src-block)))))

(ert-deftest test-ob-R/colnames-no-header-argument ()
  (org-test-with-temp-text "#+name: eg
| col |
|-----|
| a   |
| b   |

#+header: :colnames no
#+header: :var x = eg
#+begin_src R
x
#+end_src"
    (org-babel-next-src-block)
    (should (equal '(("col") ("a") ("b"))
		   (org-babel-execute-src-block)))))

(ert-deftest test-ob-R/results-file ()
  (let (ess-ask-for-ess-directory ess-history-file)
    (org-test-with-temp-text
     "#+NAME: TESTSRC
#+BEGIN_SRC R :results file
  a <- file.path(\"junk\", \"test.org\")
  a
#+END_SRC"
     (goto-char (point-min)) (org-babel-execute-maybe)
     (org-babel-goto-named-result "TESTSRC") (forward-line 1)
     (should (string= "[[file:junk/test.org]]"
		      (buffer-substring-no-properties (point-at-bol) (point-at-eol))))
     (goto-char (point-min)) (forward-line 1)
     (insert "#+header: :session\n")
     (goto-char (point-min)) (org-babel-execute-maybe)
     (org-babel-goto-named-result "TESTSRC") (forward-line 1)
     (should (string= "[[file:junk/test.org]]"
		      (buffer-substring-no-properties (point-at-bol) (point-at-eol)))))))



(ert-deftest test-ob-r/output-with-<> ()
  "make sure angle brackets are well formatted"
    (let (ess-ask-for-ess-directory ess-history-file)
      (should (string="[1] \"<X> <Y> <!>\"
[1] \"one <two> three\"
[1] \"end35\"
"
  (org-test-with-temp-text "#+begin_src R :results output
     print(\"<X> <Y> <!>\")
     print(\"one <two> three\")
     print(\"end35\")
   #+end_src
"
    (org-babel-execute-src-block))
))))


(ert-deftest test-ob-r/session-output-with->-bol ()
  "make sure prompt-like strings are well formatted, even when at beginning of line."
    (let (ess-ask-for-ess-directory ess-history-file)
      (should (string="abc
def> <ghi"
  (org-test-with-temp-text "#+begin_src R :results output :session R
     cat(\"abc
     def> <ghi\")
   #+end_src
"
    (org-babel-execute-src-block))
))))


;; (ert-deftest test-ob-r/output-with-error ()
;;   "make sure angle brackets are well formatted"
;;     (let (ess-ask-for-ess-directory ess-history-file)
;;       (should (string="Error in print(1/a) : object 'a' not found"
;;   (org-test-with-temp-text "#+begin_src R :results output
;;   print(1/a)
;;  #+end_src
;; "
;;     (org-babel-execute-src-block))
;; ))))


(ert-deftest test-ob-R/output-nonprinted ()
  (let (ess-ask-for-ess-directory ess-history-file)
    (org-test-with-temp-text
     "#+begin_src R :results output
4.0 * 3.5
log(10)
log10(10)
\(3 + 1) * 5
3^-1
1/0
#+end_src"
     (should (string= "[1] 14\n[1] 2.302585\n[1] 1\n[1] 20\n[1] 0.3333333\n[1] Inf\n" (org-babel-execute-src-block))))))

(ert-deftest test-ob-r/NA-blank ()
  "For :results value, NAs should be empty"
  (let (ess-ask-for-ess-directory ess-history-file)
    (should (equal '(("A" "B") hline ("" 1) (1 2) (1 "") (1 4) (1 4))
  (org-test-with-temp-text "#+BEGIN_SRC R :results value :colnames yes
  data.frame(A=c(NA,1,1,1,1),B=c(1,2,NA,4,4))
#+end_src"     
  (org-babel-execute-src-block))))))


(ert-deftest ob-session-async-R-simple-session-async-value ()
  (let (ess-ask-for-ess-directory
        ess-history-file
        (org-babel-temporary-directory "/tmp")
        (org-confirm-babel-evaluate nil))
    (org-test-with-temp-text
     "#+begin_src R :session R :async yes\n  Sys.sleep(.1)\n  paste(\"Yep!\")\n#+end_src\n"
     (should (let ((expected "Yep!"))
	       (and (not (string= expected (org-babel-execute-src-block)))
		    (string= expected
			     (progn
			       (sleep-for 0.200)
			       (goto-char (org-babel-where-is-src-block-result))
			       (org-babel-read-result)))))))))

(ert-deftest ob-session-async-R-simple-session-async-output ()
  (let (ess-ask-for-ess-directory
        ess-history-file
        (org-babel-temporary-directory "/tmp")
        (org-confirm-babel-evaluate nil)
        ;; Workaround for Emacs 27.  See https://orgmode.org/list/87ilduqrem.fsf@localhost
        (ess-r-post-run-hook (lambda () (ess-command (ess-calculate-width 9999)))))
    (org-test-with-temp-text
     "#+begin_src R :session R :results output :async yes\n  Sys.sleep(.1)\n  1:5\n#+end_src\n"
     (should (let ((expected "[1] 1 2 3 4 5"))
	       (and (not (string= expected (org-babel-execute-src-block)))
		    (string= expected
			     (progn
			       (sleep-for 0.200)
			       (goto-char (org-babel-where-is-src-block-result))
			       (org-babel-read-result)))))))))

(ert-deftest ob-session-async-R-named-output ()
  (let (ess-ask-for-ess-directory
        ess-history-file
        (org-babel-temporary-directory "/tmp")
        org-confirm-babel-evaluate
        (src-block "#+begin_src R :async :session R :results output\n  1:5\n#+end_src")
        (results-before "\n\n#+NAME: foobar\n#+RESULTS:\n: [1] 1")
        (results-after "\n\n#+NAME: foobar\n#+RESULTS:\n: [1] 1 2 3 4 5\n")
        ;; Workaround for Emacs 27.  See https://orgmode.org/list/87ilduqrem.fsf@localhost
        (ess-r-post-run-hook (lambda () (ess-command (ess-calculate-width 9999)))))
    (org-test-with-temp-text
     (concat src-block results-before)
     (should (progn (org-babel-execute-src-block)
                    (sleep-for 0.200)
                    (string= (concat src-block results-after)
                             (buffer-string)))))))

(ert-deftest ob-session-async-R-named-value ()
  (let (ess-ask-for-ess-directory
        ess-history-file
        org-confirm-babel-evaluate
        (org-babel-temporary-directory "/tmp")
        (src-block "#+begin_src R :async :session R :results value\n  paste(\"Yep!\")\n#+end_src")
        (results-before "\n\n#+NAME: foobar\n#+RESULTS:\n: [1] 1")
        (results-after "\n\n#+NAME: foobar\n#+RESULTS:\n: Yep!\n"))
    (org-test-with-temp-text
     (concat src-block results-before)
     (should (progn (org-babel-execute-src-block)
                    (sleep-for 0.200)
                    (string= (concat src-block results-after)
                             (buffer-string)))))))

(ert-deftest ob-session-async-R-output-drawer ()
  (let (ess-ask-for-ess-directory
        ess-history-file
        org-confirm-babel-evaluate
        (org-babel-temporary-directory "/tmp")
        (src-block "#+begin_src R :async :session R :results output drawer\n  1:5\n#+end_src")
        (result "\n\n#+RESULTS:\n:results:\n[1] 1 2 3 4 5\n:end:\n")
        ;; Workaround for Emacs 27.  See https://orgmode.org/list/87ilduqrem.fsf@localhost
        (ess-r-post-run-hook (lambda () (ess-command (ess-calculate-width 9999)))))
    (org-test-with-temp-text
     src-block
     (should (progn (org-babel-execute-src-block)
                    (sleep-for 0.200)
                    (string= (concat src-block result)
                             (buffer-string)))))))

(ert-deftest ob-session-async-R-value-drawer ()
  (let (ess-ask-for-ess-directory
        ess-history-file
        org-confirm-babel-evaluate
        (org-babel-temporary-directory "/tmp")
        (src-block "#+begin_src R :async :session R :results value drawer\n  1:3\n#+end_src")
        (result "\n\n#+RESULTS:\n:results:\n1\n2\n3\n:end:\n"))
    (org-test-with-temp-text
     src-block
     (should (progn (org-babel-execute-src-block)
                    (sleep-for 0.200)
                    (string= (concat src-block result)
                             (buffer-string)))))))

; add test for :result output
(ert-deftest ob-session-R-result-output ()
  (let (ess-ask-for-ess-directory
        ess-history-file
        org-confirm-babel-evaluate
        (org-babel-temporary-directory "/tmp")
        (src-block "#+begin_src R :session R :results output \n  1:3\n#+end_src")
        (result "\n\n#+RESULTS:\n: [1] 1 2 3\n" ))
    (org-test-with-temp-text
     src-block
     (should (progn (org-babel-execute-src-block)
                    (sleep-for 0.200)
                    (string= (concat src-block result)
                             (buffer-string)))))))

(ert-deftest ob-session-R-result-value ()
  (let (ess-ask-for-ess-directory
        ess-history-file
        org-confirm-babel-evaluate
        (org-babel-temporary-directory "/tmp"))
    (org-test-with-temp-text
     "#+begin_src R :session R :results value \n  1:50\n#+end_src"
     (should
      (equal (number-sequence 1 50)
             (mapcar #'car (org-babel-execute-src-block)))))))

;; test for printing of (nested) list
(ert-deftest ob-R-nested-list ()
  "List are printed as the first column of a table and nested lists are ignored"
  (let (ess-ask-for-ess-directory
        ess-history-file
        org-confirm-babel-evaluate
        (org-babel-temporary-directory "/tmp")
        (text "
#+NAME: example-list
- simple
  - not
  - nested
- list

#+BEGIN_SRC R :var x=example-list
x
#+END_SRC
")
(result "
#+RESULTS:
| simple |
| list   |
"))
(org-test-with-temp-text-in-file
    text
  (goto-char (point-min))
  (org-babel-next-src-block)
  (should (progn  
            (org-babel-execute-src-block)
            (sleep-for 0.200)
            (string= (concat text result)
                     (buffer-string)))))))

(ert-deftest test-ob-R/async-prompt-filter ()
  "Test that async evaluation doesn't remove spurious prompts and leading indentation."
  (let* (ess-ask-for-ess-directory
         ess-history-file
         org-confirm-babel-evaluate
         (session-name "*R:test-ob-R/session-async-results*")
         (kill-buffer-query-functions nil)
         (start-time (current-time))
         (wait-time (time-add start-time 3))
         uuid-placeholder)
    (org-test-with-temp-text
     (concat "#+begin_src R :session " session-name " :async t :results output
table(c('ab','ab','c',NA,NA), useNA='always')
#+end_src")
     (setq uuid-placeholder (org-trim (org-babel-execute-src-block)))
     (catch 'too-long
       (while (string-match uuid-placeholder (buffer-string))
         (progn
           (sleep-for 0.01)
           (when (time-less-p wait-time (current-time))
             (throw 'too-long (ert-fail "Took too long to get result from callback"))))))
     (search-forward "#+results")
     (beginning-of-line 2)
     (when (should (re-search-forward "\
:\\([ ]+ab\\)[ ]+c[ ]+<NA>[ ]*
:\\([ ]+2\\)[ ]+1[ ]+2"))
       (should (equal (length (match-string 1)) (length (match-string 2))))
       (kill-buffer session-name)))))

(provide 'test-ob-R)

;;; test-ob-R.el ends here
 
