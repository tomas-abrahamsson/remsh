;;; remsh.el --- An emacs integration to connect a shell to an Erlang node

;; Copyright (C) 2021  Tomas Abrahamsson
;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; Installation: install dependencies, using M-x package-install,
;; add melpa if needed. Then put this file in your lisp path and add
;;    (require 'remsh)
;; to your Emacs initialization file, such as .emacs.
;;
;; To use: Type
;;
;;    M-x remsh-connect
;;
;; to connect to a running Erlang node from within Emacs.
;; An inferior Erlang shell buffer for the target node will be created.


(require 's)
(require 'dash)
(require 'transient)
(require 'erlang)

(defcustom remsh-epmd-program "epmd"
  "The epmd program."
  :group 'remsh
  :type 'string)

(defvar remsh-target-node-name-hist ()
  "History variable for reading remsh target node name.")

(defvar-local remsh-current-process-name nil
  "Buffer-local variable for name of current comint process.")

(defvar-local remsh-current-process nil
  "Buffer-local variable for current comint process.")

(defvar-local remsh-current-conn-args nil
  "Buffer-local variable for current connection args.")

(defvar remsh-last-buffer nil
  "Buffer-local variable for last remsh buffer.")

(defvar remsh-last-conn-args nil
  "Buffer-local variable for current connection args.")

;;;###autoload (autoload 'remsh-connect "remsh")
(transient-define-prefix remsh-connect (&optional transient)
  "Run an inferior Erlang shell that connects to another node using -remsh.

The command line history can be accessed with  M-p  and  M-n.
The history is saved between sessions.

Entry to this mode calls the functions in the variables
`comint-mode-hook' and `erlang-shell-mode-hook' with no arguments.

The following commands imitate the usual Unix interrupt and
editing control characters:
\\{erlang-shell-mode-map}"
  :man-page "erl"
  ["Options"
   ;; Maybe should also add these options:
   ;; - epmd-port
   ;; - inetrc file
   ;; - inet_dist_connect_options
   ;; - Option for tunneling dist transport? Useful through fws. (Use tramp?)
   (remsh-connect-transient:-setcookie)
   (remsh-connect-transient:-net_ticktime)
   (remsh-connect-transient:node-name)
   (remsh-connect-transient:node-sname)]
  ["Connect"
   ;; Other potential ideas:
   ;; - t to connect and run (e)top
   ;; - n to just get node names? (then hit RET on a name to connect?)
   ("c" "connect" remsh-connect-regular)])

;;; About Erlang-style arguments, and prompts (versus gnu-style double-dash
;;; options --like=this) in option-definitions below:
;;;
;;; - Use :prompt to make it look like an Erlang-style on input
;;; - The trailing space makes the transient option presentation look nice
;;; - We will get called with "-setcookie COOKIE", so we split that
;;;   to '("-setcookie" "COOKIE") post call, see `remsh-split-transient-opts'.
;;; - The sapce beteen -setcookie and COOKIE is due to the trailing space
;;;   in :argument. It is in `remsh-split-transient-opts' too.

(transient-define-argument remsh-connect-transient:-setcookie ()
  :description  "Cookie"
  :class 'transient-option
  :shortarg "-c"
  :prompt   "-setcookie "
  :argument "-setcookie ")

(transient-define-argument remsh-connect-transient:node-sname ()
  :description  "Short node name of the remshing node"
  :class 'transient-option
  :shortarg "-s"
  :prompt   "-sname "
  :argument "-sname ")

(transient-define-argument remsh-connect-transient:node-name ()
  :description  "Node name of the remshing node"
  :class 'transient-option
  :shortarg "-n"
  :prompt   "-name "
  :argument "-name ")

(transient-define-argument remsh-connect-transient:-net_ticktime ()
  :description  "Net ticktime"
  :class 'transient-option
  :shortarg "-t"
  :prompt   "-kernel net_ticktime "
  :argument "-kernel net_ticktime ")

(defun remsh-read-target-node ()
  ;; Ask, default to read from "epmd -names"
  ;; - it could be names on other hosts as well
  ;; - epmd is not always started (or it is on a non-default port)
  ;; - epmd may not be in $PATH
  ;; Idea: @<remote-host> TAB, list names on <remote-host> (use tramp?
  ;; or erl_epmd? consider tunneling)
  (let ((nodes (remsh-safe-epmd-get-node-names)))
    (completing-read "Node: " nodes nil nil nil
                     'remsh-target-node-name-hist)))

(defun remsh-safe-epmd-get-node-names ()
  (condition-case nil (remsh-epmd-get-node-names)
    ;; If epmd is not in $PATH, for instance, then return the empty list
    (error nil)))

(defun remsh-epmd-get-node-names ()
  (remsh-parse-epmd-names (remsh-cmd-output remsh-epmd-program "-names")))

(defun remsh-parse-epmd-names (s)
  (if (s-match "epmd: up and running on port .* with data" s)
      (save-match-data
        (let ((lines (s-split "\n" s t)))
          (apply 'append
                 (-map (lambda (line)
                         (let ((m (s-match "^name \\(.*\\) at port .*" line)))
                           (when m (list (nth 1 m)))))
                       lines))))))

(defun remsh-connect-read-args ()
  (let ((target-node (remsh-read-target-node)))
    (list target-node
          (transient-args 'remsh-connect))))

(defvar remsh-node-seq 167
  "Sequence number to make remsher node names unique.")

(defun remsh-connect-regular (target-node args &optional reuse-window)
  "Run an inferior Erlang shell that connects to another node using -remsh.

The command line history can be accessed with  M-p  and  M-n.
The history is saved between sessions.

Entry to this mode calls the functions in the variables
`comint-mode-hook' and `erlang-shell-mode-hook' with no arguments.

The following commands imitate the usual Unix interrupt and
editing control characters:
\\{erlang-shell-mode-map}"
  (interactive (remsh-connect-read-args))
  (setq remsh-node-seq (1+ remsh-node-seq))
  (if (string-blank-p target-node)
      (error "No target node to connect to specified"))
  (let* ((erl-cmd-opts (remsh-split-transient-opts args))
         (long-names (s-match ".*@.*\\." target-node))
         (proc-name (remsh-buffer-name inferior-erlang-process-name ; erlang.el
                                       target-node))
         (buffer-name (remsh-buffer-name erlang-shell-buffer-name ; erlang.el
                                         target-node))
         (erl-buffer)
         (erl-process))
    (if (and long-names (member "-sname" erl-cmd-opts))
        (error (concat "Use -name instead of -sname to remsh "
                       "to a node with a long name")
               target-node erl-cmd-opts))
    (if (and long-names (not (member "-name" erl-cmd-opts)))
        ;; With long names: we must provide the remsh node's name too:
        ;; erl -name <something>@x.y -remsh name@z.y
        (let* ((remsher-base (concat "remsh-" (int-to-string (emacs-pid))
                                     "-" (int-to-string remsh-node-seq)))
               (domain-name (remsh-get-domain-name))
               (remsher-name))
          (if (not (s-match "\\." domain-name))
              (setq (domain-name "127.0.0.1")))
          (setq remsher-name (concat remsher-base "@" domain-name))
          (setq erl-cmd-opts (append erl-cmd-opts
                                     (list "-name" remsher-name)))))
    (setq erl-cmd-opts (append erl-cmd-opts (list "-remsh" target-node)))
    (setq erl-cmd-opts (append erl-cmd-opts
                               (list "-hidden") ; our node is `hidden'
                               ;; -remsh needs newshell which needs a good
                               ;; enough terminal type.
                               (list "-newshell" "-env" "TERM" "vt100")))
    (setq erl-buffer (apply 'make-comint-in-buffer
                            proc-name
                            buffer-name
                            inferior-erlang-machine ; erlang.el var
                            nil ; no "startfile"
                            erl-cmd-opts))
    (setq erl-process (get-buffer-process erl-buffer))

    ;; Avoid querying user if erl-process is running when Emacs is exited.
    (set-process-query-on-exit-flag erl-process nil)

    (if reuse-window
        (switch-to-buffer erl-buffer)
      (switch-to-buffer-other-window erl-buffer))

    ;; comint settings
    (if (and (not (eq system-type 'windows-nt))
             (eq inferior-erlang-shell-type 'newshell))
        (setq comint-process-echoes nil))
    (setq comint-input-sender 'remsh-simple-send)

    (erlang-shell-mode)

    ;; Remember (buffer-local) stuff for remsh-set-inferior-erlang-buffer:
    ;; Must be _after_ call to `erlang-shell-mode' since it somehow changes it.
    (setq remsh-current-process-name proc-name)
    (setq remsh-current-process erl-process)
    (setq remsh-current-conn-args (list target-node args)
          remsh-last-conn-args    (list target-node args))
    (setq remsh-last-buffer (current-buffer))))

(defun remsh-split-transient-opts (transient-opts)
  (let ((opt-keys '("-setcookie "
                    "-kernel net_ticktime "
                    "-name "
                    "-sname ")))
    (-flatten
     (-map (lambda (tr-opt)
             ;; Split eg "-setcookie COOKIE" to ("-setcookie" "COOKIE")
             (let ((matching-keys (--filter (s-prefix? it tr-opt) opt-keys)))
               (if (= (length matching-keys) 1)
                   (list (s-split "\s+" (car matching-keys) 'omit-nulls)
                         (s-chop-prefix (car matching-keys) tr-opt)))))
           transient-opts))))

(defun remsh-get-domain-name ()
  (s-trim (remsh-cmd-output "hostname" "-f")))

(defun remsh-buffer-name (base target-node)
  (let ((base (if (string= (substring base -1) "*")
                  (concat (substring base 0 -1) "-" target-node "*")
                (concat base "-" target-node))))
    (generate-new-buffer-name base)))

(defun remsh-simple-send (proc string)
  (comint-send-string proc (concat string "\r\n")))


(defun remsh-cmd-output (cmd &rest args)
  (with-output-to-string
    (with-current-buffer standard-output
      (apply 'call-process (append (list cmd nil t nil) args)))))


(defun remsh-set-inferior-erlang-buffer ()
  "Set current buffer to the inferior erlang buffer.
This is where compilation commands will go."
  (interactive)
  (setq inferior-erlang-process remsh-current-process)
  (setq inferior-erlang-buffer (current-buffer))
  (message "This buffer is now set to the current inferior erlang buffer"))

(defun remsh-reconnect ()
  "Reconnect to a remote node in a new buffer.
If called from a previous inferior Erlang remsh buffer, try to
reconnect to this, else reconnect using the same remsh parameters as last.
Set the new buffer as inferior, if the one we are reconneting from was."
  (interactive)
  (let* ((initially-is-inferior-erlang-buffer)
         (conn-args))
    (cond
     ((not (null remsh-current-conn-args))
      ;; Reuse buffer local var if set.
      ;; This typically means we get called from an *Erlang-<x>* buffer.
      (setq conn-args (append remsh-current-conn-args '(t)))
      (setq initially-is-inferior-erlang-buffer
            (equal (current-buffer) inferior-erlang-buffer)))
     ((not (null remsh-last-conn-args))
      ;; Fallback to reconnect to last remsh
      ;; We are probably called from a non *Erlang-<x>* buffer.
      (setq conn-args remsh-last-conn-args)
      (setq initially-is-inferior-erlang-buffer
            (equal remsh-last-buffer inferior-erlang-buffer)))
     (t
      (error "Not previously connected")))

    (apply 'remsh-connect-regular conn-args)
    (if initially-is-inferior-erlang-buffer
        (remsh-set-inferior-erlang-buffer))))

(add-hook 'erlang-mode-hook 'remsh-install-erl-keys)
(add-hook 'erlang-shell-mode-hook 'remsh-install-erl-shell-keys)

;;;###autoload
(defun remsh-install-erl-keys ()
  (local-set-key "\C-cc" 'remsh-connect)
  (local-set-key "\C-cr" 'remsh-reconnect))

;;;###autoload
(defun remsh-install-erl-shell-keys ()
  (local-set-key "\C-cs" 'remsh-set-inferior-erlang-buffer)
  (local-set-key "\C-cr" 'remsh-reconnect))

(provide 'remsh)
