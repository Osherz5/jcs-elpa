;;; build.el --- Test the configuration  -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require 'pakcage)

(setq package-archives
      '(("jcs" . "https://jcs-emacs.github.io/elpa/elpa/")))

(setq package-enable-at-startup nil  ; To avoid initializing twice
      package-check-signature nil)

(package-initialize)

(message "%s" package-archive-contents)

;; Local Variables:
;; coding: utf-8
;; no-byte-compile: t
;; End:
;;; build.el ends here
