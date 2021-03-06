#lang cur
(require (rename-in (except-in cur/stdlib/equality == refl)
                    [ML-= ==]
                    [ML-refl refl])
         cur/stdlib/sugar
         cur/stdlib/nat
         cur/ntac/base
         cur/ntac/standard
         cur/ntac/ML-rewrite
         "rackunit-ntac.rkt")

;; tests rewrite

;;plus-0-n raw term
(define plus-0-n-term  (λ [n : Nat] (refl Nat n)))
(::
 plus-0-n-term
 (forall [n : Nat] (== Nat (plus 0 n) n)))

(define-theorem plus-0-n
  (forall [n : Nat] (== Nat (plus 0 n) n))
  by-intro
  simpl
  reflexivity)


;; mult-0-plus
;; - uses rewrite
;; raw term

(::
 (λ [n : Nat]
    ((λ [H : (== Nat (plus 0 n) n)]
       (new-elim
        H
        (λ [n0 : Nat] [n : Nat]
           (λ [H : (== Nat n0 n)]
             (Π [m : Nat]
                (== Nat (mult n0 m) (mult n0 m)))))
        (λ [n0 : Nat]
          (λ [m : Nat]
            (refl Nat (mult n0 m))))))
     (plus-0-n-term n)))
 (∀ [n : Nat] [m : Nat]
    (== Nat (mult (plus 0 n) m) (mult n m))))
;; raw term, directly
(::
 (λ [n : Nat]
   (new-elim
    (plus-0-n-term n)
    (λ [n0 : Nat] [n : Nat]
       (λ [H : (== Nat n0 n)]
         (Π [m : Nat]
            (== Nat (mult n m) (mult n m)))))
    (λ [n : Nat]
      (λ [m : Nat]
        (refl Nat (mult n m))))))
 (∀ [n : Nat] [m : Nat]
    (== Nat (mult (plus 0 n) m) (mult n m))))

(define-theorem mult-0-plus
  (∀ [n : Nat] [m : Nat]
     (== Nat (mult (plus 0 n) m) (mult n m)))
  (by-intro n)
  by-intro
  (by-rewrite plus-0-n n)
  reflexivity)
