#lang cur
(require cur/stdlib/sugar
         cur/stdlib/equality
         cur/ntac/base
         cur/ntac/standard
         cur/ntac/rewrite
         "../rackunit-ntac.rkt"
         rackunit/turnstile)

;; This file is similar to Poly.rkt, except it tries to use as many implicit
;; args as possible

;; the examples here are split into this separate file bc the
;; implicitly generated ids make the tests brittle

(data nat : 0 Type
      (O : nat) ; letter capital "O"
      (S : (-> nat nat)))

;; * = "full" version; as opposed to hidden-arg version
(define-datatype list [X : Type] : -> Type
  [nil* : (list X)]
  [cons* : X (list X) -> (list X)])

(define-implicit nil = nil* 1)
(define-implicit cons = cons* 1 _ inf)

;; TODO: define-implicit needs:
;; - define pattern abbreviations
;; - allow recursive references
(define/rec/match app_ : [X : Type] (list X) (list X) -> (list X)
  [(nil* _) l2 => l2]
  [(cons* _ h t) l2 => (cons h (app_ X t l2))])

(define-implicit app = app_ 1)

(define/rec/match length_ : [X : Type] (list X) -> nat
  [(nil* _) => O]
  [(cons* _ h t) => (S (length_ X t))])

(define-implicit length = length_ 1)

(define-theorem eq-remove-S
  (∀ [n : nat] [m : nat]
     (-> (== n m)
         (== (S n) (S m))))
  by-intros
  (by-rewrite H57)
  reflexivity)

(define-theorem length-app-sym/abbrv
  (∀ [X : Type] [l1 : (list X)] [l2 : (list X)] [x : X] [n : nat]
     (-> (== (length (app l1 l2)) n)
         (== (length (app l1 (cons x l2))) (S n))))
  (by-intros X l1)
  (by-induction l1 #:as [() (x xs IH)] #:params (X))
  ; induction 1: nil -----
  by-intros
  (by-rewrite H63)
  reflexivity
  ; induction 2: cons -----
  by-intros
  (by-apply eq-remove-S)
  (by-destruct n #:as [() (n-1)])
  ;; destruct 2a: z -----
  (by-inversion H66)
  elim-False
  (by-assumption)
  ;; destruct 2b: (s n-1) -----
  (by-apply IH)
  (by-inversion H66)
  (by-rewrite H68)
  reflexivity)

(check-type length-app-sym/abbrv
  : (∀ [X : Type] [l1 : (list X)] [l2 : (list X)] [x : X] [n : nat]
       (-> (== (length (app l1 l2)) n)
           (== (length (app l1 (cons x l2))) (S n)))))