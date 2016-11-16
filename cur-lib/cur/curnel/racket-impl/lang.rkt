#lang racket/base
#| TODO NB XXX Before merging:
 | 1. Handle all TODOs
 | 2. ensure all error messages are reported with surface expression and source information
 | 3. be consistent about using #' vs attribute. (I seem to think attribute do more than #' even when
 |    referring to pattern variables, but I'm not sure that's true)
 |    (attribute ) should only be used when referring to non-syntax valued attributes.
 | 4. Test
 |    - a. things that should work
 |    - b. things that shouldn't
 | 5. Ensure backwards compatibility
 | ~6. Have Stephen review code/maybe rewrite using his library.~--Library requires term/type/kind
 |     distinction, and has a lot of dependenices. Would complicate core too much.
 | 7. Get rid of boilerplatey stuff; superseded by using library.
 | 8. Abstract errors/make consistent
 |#
;; NB: have to use erased terms in types because the erased terms may have renamed
;; variables, e.g., from the expansion that happens in get-type.
(require
 (only-in racket/struct struct->list)
 ;; TODO: Don't use curry; results in bad source location for procedures
 (only-in racket/function curry)
 (only-in racket/list drop)
 (for-syntax
  racket/base
  (only-in racket/function curry)
  (only-in racket/syntax format-id with-syntax*)
  syntax/parse))
(provide
 (rename-out
  [cur-type Type]
  [cur-define define]
  [cur-λ λ]
  [cur-Π Π]
  [cur-app #%app]
  [cur-axiom axiom]
  [cur-data data]
  [cur-elim elim]
  #;[cur-var #%variable-reference])
 ;; TODO: export all subforms?
 require only-in for-syntax
 provide
 ;; TODO: Who needs top?
; #%top
 ;; TODO: Need to not export datum
 #%datum
 ;(struct-out Type)
 #%module-begin)


;;; Testing
;;; ------------------------------------------------------------------------
(begin-for-syntax
  (module+ test
    (require chk)))

;;; Debugging
;;; ------------------------------------------------------------------------
(require
 racket/trace
 (for-syntax
  racket/trace))
(begin-for-syntax
  (define (maybe-syntax->datum x)
    (if (syntax? x)
        (syntax->datum x)
        x))

  (current-trace-print-args
   (let ([ctpa (current-trace-print-args)])
     (lambda (s l kw l2 n)
       (ctpa s (map maybe-syntax->datum l) kw l2 n))))
  (current-trace-print-results
   (let ([ctpr (current-trace-print-results)])
     (lambda (s l n)
       (ctpr s (map maybe-syntax->datum l) n))))

  (require racket/list)
  (define (and-print . e)
    (map (compose displayln maybe-syntax->datum) e)
    (last e)))

;;; Reflected (compile-time) and reified (run-time) representations of Curnel terms
;;; ------------------------------------------------------------------------

;; Reified
;; TODO: all "erased" things are really "reified"; their type annotations aren't erased, just turned
;; into syntax properties.
;; ----------------------------------------------------------------

;; All reified expressions have the syntax-property 'type.
(begin-for-syntax
  (define (reified-get-type e)
    (syntax-property e 'type))

  (define (reified-set-type e t)
    (syntax-property e 'type t)))

; The run-time representation of univeres. (Type i), where i is a Nat.
(struct Type (level) #:transparent)

; The run-time representation of Π types. (Π t f), where is a type and f is a procedure that computes
; the body type given an argument.
(struct Π (t f))
;; TODO: Should unierses and Π types have a run-time representation?

; The run-time representation of an application is a Racket plain application.
; (#%plain-app e1 e2)

; The run-time representation of a function is a Racket plain procedure.
; (#%plain-lambda (f) e)
(begin-for-syntax
  ;; A syntax class for detecting the constructor of a struct
  (define-syntax-class (constructor constr-syn)
    (pattern x:id
             #:attr constr (syntax-property #'x 'constructor-for)
             #:when (and (attribute constr) (free-identifier=? constr-syn #'constr))))

  (define-syntax-class reified-universe
    #:literals (#%plain-app quote Type)
    (pattern (#%plain-app (~var constr (constructor #'Type)) ~! (quote level-syn:nat))
             #:attr level (syntax->datum #'level-syn)))

  ;; TODO: Pattern to abstract
  (define (reify-universe syn i)
    (reified-set-type (cur-local-expand (quasisyntax/loc syn (Type (quote i))))
                      (reified-get-type syn)))

  (define-syntax-class reified-pi
    #:literals (#%plain-app #%plain-lambda Π)
    (pattern (#%plain-app (~var constr (constructor #'Π)) ~! type-ann (#%plain-lambda (name) body))))

  (define (reify-pi syn x t e)
    (reified-set-type (cur-local-expand (quasisyntax/loc syn (Π #,t (#%plain-lambda (#,x) #,e))))
                      (reified-get-type syn)))

  (define-syntax-class reified-lambda
    #:literals (#%plain-lambda)
    (pattern (#%plain-lambda (name) body)
             ;; NB: Require type anotations on variables in erased syntax.
             #:attr type-ann (syntax-property #'name 'type)))

  (define (reify-lambda syn x e)
    (reified-set-type (quasisyntax/loc syn (#%plain-lambda (#,x) #,e))
                      (reified-get-type syn)))

  (define-syntax-class reified-app
    #:literals (#%plain-app)
    (pattern (#%plain-app operator operand)))

  (define (reify-app syn e . rest)
    (reified-set-type
     (for/fold ([app (quasisyntax/loc syn #,e)])
               ([arg rest])
       (quasisyntax/loc syn (#%plain-app #,app #,arg)))
     (reified-get-type syn)))

  (define-syntax-class reified-elim
    #:literals (#%plain-app)
    (pattern (#%plain-app x:id target motive methods ...)
             #:when (syntax-property #'x 'elim)))

  (define (reify-elim syn x d m methods)
    (reified-set-type (quasisyntax/loc syn (#%plain-app #,x #,d #,m #,@methods))
                      (reified-get-type syn)))

  ;; Reification: turn a compile-time term into a run-time term.
  ;; This is done implicitly via macro expansion; each of the surface macros define the
  ;; transformation.
  ;; We define one helper for when we need to control reification.
  (define (cur-local-expand e)
    (local-expand e 'expression null))

  ;; For restricting top-level identifiers, such as define.
  (define-syntax-class top-level-id
    (pattern x:id
             #:fail-unless (case (syntax-local-context)
                             [(module top-level module-begin) #t]
                             [else #f])
             (raise-syntax-error
              (syntax->datum #'x)
              (format "Can only use ~a at the top-level."
                      (syntax->datum #'x))
              this-syntax)))

  ;;; Reified composite forms

  ;; Constants are nested applications with a constructor or inductive type in head position:
  ;; refieid-constant ::= Θ[c]
  ;; Θ ::= hole (Θ e)
  (define-syntax-class reified-constant
    (pattern app:reified-app
             #:with e:reified-constant #'app.operator
             ;; NB: Append
             ;; TODO: This one should be eliminated; this is used a lot and could become a bottleneck.
             ;; Maybe need a pre-reified-constant and then reverse the list once
             #:attr args (append (attribute e.args) (list #'app.operand))
             #:attr constr #'e.constr
             #:attr constructor-index (attribute e.constructor-index))

    (pattern constr:id
             #:attr args '()
             #:attr constructor-index (syntax-property #'constr 'constructor-index)
             #:when (syntax-property #'constr 'constant)))

  ;; Telescopes are nested Π types.
  (define-syntax-class reified-telescope
    (pattern e:reified-pi
             #:with tmp #'e.body
             #:declare tmp reified-telescope
             ;; TODO: Body is a bad name for this
             #:attr body #'tmp.body
             #:attr args (cons #'e.name (attribute tmp.args))
             ;; TODO: anns in all telescopes are unused.
             ;; TODO: args in all telescopes should probably be number indicating number of args.
             #:attr anns (cons #'e.type-ann (attribute tmp.anns)))

    (pattern (~and body (~not _:reified-pi))
             #:attr args '()
             #:attr anns '()))

  ;; Axiom telescopes are nested Π types with a universe or constant as the final result
  (define-syntax-class reified-axiom-telescope
    (pattern e:reified-telescope
             #:with (~and body (~or _:reified-universe _:reified-constant)) #'e.body
             #:attr args (attribute e.args)
             #:attr anns (attribute e.anns)))

  ;; Inductive telescopes are nested Π types with a universe as the final result.
  (define-syntax-class reified-inductive-telescope
    (pattern e:reified-telescope
             #:with body:reified-universe #'e.body
             #:attr args (attribute e.args)
             #:attr anns (attribute e.anns)))

  ;; Constructor telescopes are nested Π types that return a constant with the inductive type type in
  ;; head position.
  (define-syntax-class (reified-constructor-telescope inductive)
    (pattern e:reified-telescope
             ;; TODO: Maybe use patterns in with instead of declare?
             #:with body:reified-constant #'e.body
;             #:do [(displayln #'body.constr)
;                   (displayln inductive)
;                   (displayln (bound-identifier=? #'body.constr inductive))
;                   (displayln (free-identifier=? #'body.constr inductive))]
             ;; TODO shouldn't these be bound? Except, see above
             #:when (free-identifier=? #'body.constr inductive)
             #:attr args (attribute e.args)
             #:attr anns (attribute e.anns)
             #:attr recursive-args
             (for/list ([x (attribute args)]
                        [t (attribute anns)]
                        [i (in-naturals)]
                        #:when (syntax-parse t
                                 ;; TODO: Can e be a telescope whose body is a reified-constant? Model
                                 ;; suggests yes; see method-type recursive case
                                 [e:reified-constant
                                  (free-identifier=? #'e.constr inductive)]
                                 [_ #f]))
               ;; NB: Would like to return x, but can't rely on names due to alpha-conversion
               i))))

;; TODO: Should this be specified last? Probably should work on reified form in curnel, and let users
;; use reflected forms. But see later TODO about problems with types of types, which Types as Macros
;; current approach doesn't support well...

;; Reflected
;; ----------------------------------------------------------------
(begin-for-syntax
  (define-syntax-class reflected-universe
    #:literals (cur-type)
    (pattern (cur-type i:nat)))

  (define-syntax-class reflected-pi
    #:literals (cur-Π)
    (pattern (cur-Π (name : type-ann) body)))

  (define-syntax-class reflected-lambda
    #:literals (cur-λ)
    (pattern (cur-λ (name : type-ann) body)))

  (define-syntax-class reflected-app
    #:literals (cur-app)
    (pattern (cur-app operator operand)))

  ;; Reflection: turn a run-time term back into a compile-time term.
  ;; This is done explicitly when we need to pattern match.
  (define (cur-reflect e)
    (syntax-parse e
      #:literals (#%plain-app #%plain-lambda)
      [x:id e]
      [e:reified-universe
       #`(cur-type e.level-syn)]
      [e:reified-pi
       #`(cur-Π (e.name : #,(cur-reflect #'e.type-ann)) #,(cur-reflect #'e.body))]
      [e:reified-app
       #`(cur-app #,(cur-reflect #'e.operator) #,(cur-reflect #'e.operand))]
      [e:reified-lambda
       #`(cur-λ (e.name : #,(cur-reflect #'e.type-ann)) #,(cur-reflect #'e.body))]
      [e:reified-elim
       #`(cur-elim #,(cur-reflect #'e.target) #,(cur-reflect #'e.motive)
                   #,(map cur-reflect (attribute e.methods)))])))

;;; Intensional equality
;;; ------------------------------------------------------------------------
(begin-for-syntax
  (define (subst v x e)
    (syntax-parse e
      [y:id
       #:when (bound-identifier=? e x)
       v]
      [(e ...)
       #`(#,@(map (lambda (e) (subst v x e)) (attribute e)))]
      [_ e]))
  (module+ test
    (define syn-eq? (lambda (x y) (equal? (syntax->datum x) (syntax->datum y))))
    (chk
     #:eq bound-identifier=? (subst #'z #'x #'x) #'z
     #:eq bound-identifier=? (subst #'z #'x #'y) #'y
     ; TODO Not sure how to capture this test; x isn't getting the "right" binding...
     ; but syntax-local-introduce only works in the macro expander ...
     ; maybe should do subst by applying?
     ;; #:eq syn-eq? (subst #'z #'x (expand-syntax-once #'(#%plain-lambda (y) x))) #'(#%plain-lambda (y) z)
     #:eq syn-eq? (subst #'z #'x (expand-syntax-once #'(#%plain-lambda (x) x))) #'(#%plain-lambda (x) x)))


  ;; TODO: Should this be parameterizable, to allow for different eval strategies if user wants?
  (define (cur-eval syn)
    (syntax-parse syn
      [_:reified-universe syn]
      [_:id syn]
      [e:reified-pi
       (reify-pi syn #'e.name (cur-eval #'e.type-ann) (cur-eval #'e.body))]
      [e:reified-app
       #:with a (cur-eval #'e.operand)
       (syntax-parse (cur-eval #'e.operator)
         [f:reified-lambda
          (cur-eval (subst #'a #'f.name #'f.body))]
         [e1-
          (reify-app syn #'e1- #'a)])]
      [e:reified-elim
       #:with target:reified-constant #'e.target
       ;; TODO: Maybe recursive args should be a syntax property on the constructor
       #:do [(define recursive-args
               (syntax-property (attribute target.constr) 'recursive-arg-positions))]
       ;; TODO: Performance hack: use unsafe version of list operators and such for internal matters
       (cur-eval
        (apply reify-app syn (list-ref (attribute e.methods) (attribute target.constructor-index))
               (for/fold ([m-args (attribute target.args)])
                         ([arg (attribute target.args)]
                          [i (in-naturals)]
                          [j recursive-args]
                          ;; TODO: Change all these =s to eq?s
                          #:when (= i j))
                 ;; TODO: Badness 10000; append in a loop
                 (append m-args (list (reify-elim syn #'e.x arg #'e.motive (attribute e.methods)))))))]
      [e:reified-lambda
       (reify-lambda syn #'e.name (cur-eval #'e.body))]
      [_ (error 'cur-eval "Something has gone horribly wrong: ~a" syn)]))

  (define (cur-normalize e)
    ;; TODO:
    ;; Beta reduce until no more betas
    ;; Eta expand while non-lambda term that is of function type.
    ;; alternative: do equality up-to eta expansion. might be
    ;; Reify the runtime syntax into the surface syntax.
    (cur-eval (cur-local-expand e))
    #;(reify (eta-expand (beta-reduce (cur-local-expand e)))))

  ;; When are two Cur terms intensionally equal? When they normalize the α-equivalent reified syntax.
  (define (cur-equal? t1 t2)
    (syntax-parse #`(#,(cur-normalize t1) #,(cur-normalize t2))
      [(x:id y:id)
       (free-identifier=? #'x #'y)]
      [(A:reified-universe B:reified-universe)
       (= (attribute A.level) (attribute B.level))]
      ;; TODO: Can we compile surface patterns into the expanded representation? Do we need to? Maybe
      ;; reify does that work
      #;[((cur-Π (x:id : A₁) B₁)
          (cur-Π (y:id : A₂) B₂))]
      [(e1:reified-pi e2:reified-pi)
       (and (cur-equal? #'e1.type-ann #'e2.type-ann)
            (cur-equal? #'e1.body (subst #'e1.name #'e2.name #'e2.body)))]
      [(e1:reified-elim e2:reified-elim)
       (and (cur-equal? #'e1.target #'e2.target)
            (cur-equal? #'e1.motive #'e2.motive)
            (map cur-equal? (attribute e1.methods) (attribute e2.methods)))]
      [(e1:reified-app e2:reified-app)
       (and (cur-equal? #'e1.operator #'e2.operator)
            (cur-equal? #'e1.operand #'e2.operand))]
      [(e1:reified-lambda e2:reified-lambda)
       (and (cur-equal? #'e1.type-ann #'e2.type-ann)
            (cur-equal? #'e1.body (subst #'e1.name #'e2.name #'e2.body)))]
      [_ #f])))

;;; TODO: subtyping

;;; Nothing before here should be able to error. Things after here might, since they are dealing with
;;; terms before they are type-checked.

;;; Errors
;;; ------------------------------------------------------------------------
(begin-for-syntax
  ;; TODO: Should be catchable; maybe should have hierarchy. See current Curnel

  ;; syn: the source syntax of the error
  ;; expected: a format string describing the expected type or term.
  ;; term: a datum or format string describing the term that did not match the expected property. If a
  ;;       format string, remaining args must be given as rest.
  ;; type: a datum or format string describing the type that did not match the expected property. If a
  ;;       format string, remaining args must be given as rest.
  ;; rest: more datums
  (define (cur-type-error syn expected term type . rest)
    (raise-syntax-error
     'core-type-error
     (apply
      format
      (format "Expected ~a, but found ~a of type ~a."
              expected
              term
              type)
      rest)
     syn)))

;;; Types as Macros; type system helpers.
;;; ------------------------------------------------------------------------
(begin-for-syntax
  (define (fresh [x #f])
    (datum->syntax x (gensym (if x (syntax->datum x) 'x))))

  ;; Helpers; based on Types as Macros
  (define (set-type e t)
    (syntax-property e 'type (syntax-local-introduce t)))

  ;; TODO: dead code.
  ;; TODO: expansion is necessary, but "type erasure" isn't. In fact, we might need types, e.g., when
  ;; doing compile-time eval and reflection.
  (define (erase-type e)
    (cur-local-expand e))

  (define (merge-type-props syn t)
    ;; TODO: Check that list is consistent and report error if not
    (if (pair? t) (car t) t))

  ;; NB: Get type returns
  ;; #`((zv ...) e : t)
  ;; where zv ... are the alpha-renamed bindings from ctx in e and t
  ;;       e is the well-typed compiled Cur term
  ;;       t is a type that has not be checked for validity (since doing so eagerly may result in an
  ;;       infinite loop, e.g., with universes).
  (define (get-type e #:ctx [ctx #'()])
    (syntax-parse ctx
      #:datum-literals (:)
      #:literals (#%plain-lambda let-values)
      ;; TODO: Does this need to be type-checked? I think not
      [([x:id t] ...)
       #:with (yv ...) (map fresh (attribute x))
       #:with (#%plain-lambda (zv ...) (let-values () (let-values () e2)))
       (cur-local-expand
        #`(lambda (#,@(map set-type (attribute yv) (attribute t)))
            (let-syntax ([x (make-rename-transformer (set-type #'yv #'t))] ...)
              #,e)))
       ;; TODO: Not sure if this is sensible; testing seemed to indicate "no"
       ;#:with (yt ...) (map fresh (attribute x))
       ;#:with (#%plain-lambda (zt ...) (let-values () (let-values () t2)))
       #;(cur-local-expand
          #`(lambda (yt ...)
              (let-syntax ([x (make-rename-transformer (set-type #'yt #'t))] ...)
                #,(merge-type-props e (syntax-property (attribute e2) 'type)))))
       ;; TODO: if t2 is ever #f, an error should be raised. However, this error should be a last resort;
       ;; typed macros should be able to provide their own error message.
       ;; 1. could use exceptions
       ;;    + always get a type error
       ;;    + simplified interface
       ;;    - exceptions feel weird to me
       ;;    - have to remember to handle them in macros
       ;; 2. could pass in an error message
       ;;    + statically enforced that you give a more specific error message
       ;;    + always get a type error
       ;;    - adds some burden to use
       ;;    - may not cover all use cases
       ;; 3. could put in error monad
       ;;    + flexible
       ;;    - may get random, unrelated error if you forget to handle
       ;; look into how types as macros does this
       #:do [(define maybe-t2 (syntax-property (attribute e2) 'type))]
       #:fail-unless maybe-t2
       (raise-syntax-error
        'core-type-error
        "Expected a well-typed Curnel term, but found something else."
        (attribute e2))
       #:with t2 (cur-local-expand (syntax-local-introduce (merge-type-props e maybe-t2)))
       #`((zv ...) (e2 : t2))]))


  ;; TODO: Am I misusing syntax classes to do error checking and not just (or really, any) parsing?

  ;; Make typing easier

  ;; Expect *some* well-typed expression.
  ;; NB: Cannot check that type is well-formed eagerly, otherwise infinite loop.
  (define-syntax-class cur-typed-expr
    (pattern e:expr
             #:with (_ (erased : t)) (get-type #'e)
             ;; TODO: Why normalize here instead of in get-type?
             #:attr type (cur-normalize #'t)))

  ;; Expect *some* well-typed expression, in an extended context.
  (define-syntax-class (cur-typed-expr/ctx ctx)
    (pattern e:expr
             #:with ((name ...) (erased : type)) (get-type #'e #:ctx ctx)))

  ;; Expected a well-typed expression of a particular type.
  (define-syntax-class (cur-expr-of-type type)
    (pattern e:cur-typed-expr
             ;; TODO: Subtyping?
             #:fail-unless (cur-equal? #'e.type type)
             (cur-type-error
              this-syntax
              "term of type ~a"
              (syntax->datum #'e)
              (syntax->datum #'e.type)
              (syntax->datum type))
             #:attr erased #'e.erased))

  ;; Expect a well-typed function.
  (define-syntax-class cur-procedure
    (pattern e:cur-typed-expr
             #:attr erased #'e.erased
             #:attr type #'e.type
             #:fail-unless (syntax-parse #'e.type [_:reified-pi #t] [ _ #f])
             (raise-syntax-error
              'core-type-error
              (format "Expected function, but found ~a of type ~a"
                      ;; TODO Should probably be using 'origin  in more error messages. Maybe need principled
                      ;; way to do that.
                      (syntax->datum #'e)
                      ;; TODO: Not always clear how to resugar; probably need some function for this:
                      ;; 1. Sometimes, origin is the best resugaring.
                      ;; 2. Sometimes, just syntax->datum is.
                      ;; 3. Sometimes, it seems none are, because the type was generated in the macro
                      ;; (e.g. the types of univeres) and origin gives a very very bad
                      ;; resugaring.. Maybe a Racket bug? Bug seems likely, happens only with Type and
                      ;; Pi, which go through struct. Other types seem fine.
                      ;(syntax->datum (last (syntax-property (attribute e) 'origin)))
                      ;(syntax->datum #'e.type)
                      #;(third (syntax-property #'f-type 'origin))
                      (syntax->datum (last (syntax-property #'e.type 'origin))))
              #'e)
             #:with tmp #'e.type
             #:declare tmp reified-pi
             #:attr arg-type #'tmp.type-ann
             ;; TODO: Bad varible naming; why "type-name"? is it clear that that is the name used in
             ;; the result type to refer to the argument? I think not.
             #:attr type-name #'tmp.name
             #:attr result-type #'tmp.body))

  ;; Expect a well-typed expression whose type is a universe (kind)
  (define-syntax-class cur-kind
    (pattern e:cur-typed-expr
             ;; TODO There's got to be a better way
             #:fail-unless (syntax-parse #'e.type [_:reified-universe #t] [_ #f])
             (cur-type-error
              #'e
              "a kind (a type whose type is a universe)"
              (syntax->datum #'e)
              (syntax->datum (last (syntax-property #'e.type 'origin))))
             #:attr erased #'e.erased
             #:attr type #'e.type))

  (define-syntax-class cur-typed-axiom-telescope
    (pattern e:cur-typed-expr
             #:fail-unless (syntax-parse #'e.erased [_:reified-axiom-telescope #t] [_ #f])
             (cur-type-error
              #'e
              "an axiom telescope (a nested Π type whose final result is a universe or a constant)"
              (syntax->datum #'e)
              (syntax->datum (last (syntax-property #'e.type 'origin))))
             #:with erased:reified-axiom-telescope #'e.erased
             #:attr args (attribute erased.args)
             #:attr anns (attribute erased.anns)))

  ;; TODO: Lots of code duplication here... copy and past abstraction...
  ;; investigate some way of auto inheriting attributes, lifting a reified class to a typed class?
  (define-syntax-class cur-typed-inductive-telescope
    (pattern e:cur-typed-expr
             #:fail-unless (syntax-parse #'e.erased [_:reified-inductive-telescope #t] [_ #f])
             (cur-type-error
              #'e
              "an inductive telescope (a nested Π type whose final result is a universe)"
              (syntax->datum #'e)
              (syntax->datum (last (syntax-property #'e.type 'origin))))
             #:attr erased #'e.erased
             #:with tmp #'e.erased
             #:declare tmp reified-inductive-telescope
             #:attr args (attribute tmp.args)
             #:attr anns (attribute tmp.anns)))

  ;; The inductive type must be first in the ctx, which makes sense anyway
  ;; TODO Bad variable name
  (define-syntax-class (cur-typed-constructor-telescope D)
    (pattern e:cur-typed-expr
             #:fail-unless (syntax-parse #'e.erased [(~var _ (reified-constructor-telescope D)) #t] [_ #f])
             (cur-type-error
              #'e
              "a constructor telescope (a nested Π type whose final result is ~a applied to any indices)"
              (syntax->datum #'e.erased)
              (syntax->datum (last (syntax-property #'e.type 'origin)))
              (syntax->datum D))
             #:attr erased #'e.erased
             #:with tmp #'e.erased
             #:declare tmp (reified-constructor-telescope D)
             #:attr args (attribute tmp.args)
             #:attr recursive-args (attribute tmp.recursive-args)
             #:attr anns (attribute tmp.anns)))
  )

;;; Typing
;;;------------------------------------------------------------------------

(begin-for-syntax
  (require (for-syntax racket/base))

  ;; Can only be used under a syntax-parse
  (define-syntax (⊢ syn)
    (syntax-case syn (:)
      [(_ e : t)
       (quasisyntax/loc syn
         (set-type
          (quasisyntax/loc this-syntax e)
          (quasisyntax/loc this-syntax t)))])))

(define-syntax (cur-type syn)
  (syntax-parse syn
    [(_ i:nat)
     (⊢ (Type i) : (cur-type #,(add1 (syntax->datum #'i))))]))

(define-syntax (cur-Π syn)
  (syntax-parse syn
    #:datum-literals (:)
    [(_ (x:id : t1:cur-kind) (~var e (cur-typed-expr/ctx #`([x t1.erased]))))
     #:declare e.type cur-kind
     (⊢ (Π t1.erased (#%plain-lambda (#,(car (attribute e.name))) e.erased)) : e.type)]))

(define-syntax (cur-λ syn)
  (syntax-parse syn
    #:datum-literals (:)
    [(_ (x:id : t1:cur-kind) (~var e (cur-typed-expr/ctx #`([x t1.erased]))))
     #:declare e.type cur-kind
     ;; TODO: Wish to use t1 instead of t1.erased, to keep types in reflected syntax. But only the
     ;; erased syntax has the right bindings due to how get-type handles bindings/renamings
     (⊢ (#%plain-lambda (#,(car (attribute e.name))) e.erased) : (cur-Π (#,(car (attribute e.name)) : t1.erased) e.type))]))

(begin-for-syntax
  ;; TODO: Maybe mulit-artiy functions would be a good thing. Always currying probably incurs a
  ;; performance hit.
  (define (cur-app* e args)
    (if (null? args)
        e
        (cur-app* #`(cur-app #,e #,(car args)) (cdr args)))))

(define-syntax (cur-app syn)
  (syntax-parse syn
    [(_ e1:cur-procedure (~var e2 (cur-expr-of-type #'e1.arg-type)))
     ;; TODO: This computation seems to be over erased terms, hence t2^ has no type.
     ;; Need to reify t2^ back into the core macros, so it's type will be computed if necessary.
     ;; This may be part of a large problem/solution: need to reify terms after evaluation, so we can
     ;; pattern match on the core syntax and not the runtime representation.
     ;; HMM.. this is not always true.. sometimes it's un-erased?
     ;; NB: Okay, always using reflected syntax as type works so far, but always need to expand syntax in
     ;; get-type... why? .. because all macros exected reified syntax... why not just redesign them to
     ;; expect reflected syntax?
     ;; TODO: could use #%app here, and lambda in the cur-λ, but those do get expanded... this might
     ;; speed up macro expansion... hm. sketchy argument.... also ensures in the normal form i expect?
     ;; not really...
     (⊢ (#%plain-app e1.erased e2.erased) :
        #,(cur-reflect (subst #'e2.erased #'e1.type-name #'e1.result-type)))]))

(begin-for-syntax
  (define (define-typed-identifier name type erased-term (y (fresh name)))
    #`(begin
        (define-syntax #,name
          (make-rename-transformer
           (set-type (quasisyntax/loc #'#,name #,y)
                     (quasisyntax/loc #'#,name #,type))))
        (define #,y #,erased-term))))

(define-syntax (cur-define syn)
  (syntax-parse syn
    #:datum-literals (:)
    [(_:top-level-id name:id body:cur-typed-expr)
     (define-typed-identifier #'name #'body.type #'body.erased)]))

(define-syntax (cur-axiom syn)
  (syntax-parse syn
    #:datum-literals (:)
    [(_:top-level-id n:id : type:cur-typed-axiom-telescope)
     ;; TODO: Hmmm no longer can use 'constant to mean constructor or inductive type, but maybe to
     ;; mean axioms too is okay.
     #:do [(define name (syntax-property #'n'constant #t))]
     #:with axiom (fresh name)
     #:with make-axiom (format-id name "make-~a" #'axiom #:props name)
     #`(begin
         ;; TODO: these .args names should either be in terms of the source, or arbirary. Right
         ;; now, they are alpha-renamed source.
         ;; Probably should be arbitrary since it shouldn't be possible to directly observe them, and
         ;; then we wouldn't need to keep names around, just number of args.
         (struct axiom #,(attribute type.args) #:transparent #:reflection-name '#,name)
         #,(define-typed-identifier name #'type.erased #'((curry axiom)) #'make-axiom)
         ;; NB: Need a predicate with a known name to generate eliminators, but need a fresh
         ;; name for struct to handle typing.
         (define #,(format-id name "~a?" name) #,(format-id name "~a?" #'axiom)))]))

(define-for-syntax (syntax-properties e als)
  (for/fold ([e e])
            ([pair als])
    (syntax-property e (car pair) (cdr pair))))

;; TODO: Strict positivity checking
;; NB: To simplify checking, and maximize reuse, we cur-data generates into a series of cur-axioms,
;; a macro that performs positivity checking (TODO), and a macro that generates elimination definition.
;; The advantage of this over doing everying in cur-data (via e.g. helper functions) is that we reuse
;; macro expansion to handle issues of alpha-equivalence.
(define-syntax (_cur-constructor syn)
  (syntax-parse syn
   #:datum-literals (:)
   ;; TODO: Maybe that local expand should be elsewhere, e.g., cur-typed-constructor
   [(_ name (D) : (~var type (cur-typed-constructor-telescope (cur-local-expand #'D))))
    #`(cur-axiom #,(syntax-properties
                    #'name
                    `((recursive-arg-positions . ,(attribute type.recursive-args)))) : type)]))

(define-syntax (_cur-elim syn)
  (syntax-parse syn
   [(_ elim-name D c:cur-typed-expr ...)
    ;; TODO: Efficiency: t's are getting checked twice. Can we pass argument info on the syntax-properties of c?
    ;; TODO cur-local-expand
    #:do [(define D- (cur-local-expand #'D))
          (define number-of-constructors (syntax-property D- 'number-of-constructors))
          ;; TODO: Could pass constructor-predicate as a syntax-property...
          ;; TODO: Passing identifiers as syntax properties seems to lose some binding information?
          ;; couldn't do it with elim-name
          (define constructor-predicates (map (curry format-id #'D "~a?") (attribute c)))
          (define method-names (map fresh (attribute c)))]
    #:with ((~var t (cur-typed-constructor-telescope D-)) ...) #'(c.type ...)
    #:with p (syntax-property D- 'params)
    #`(define elim-name
        ;; NB: _ is the motive; necessary in the application of elim for compile-time evaluation,
        ;; which may need to recover the type.
        (lambda (e _ #,@method-names)
          (let loop ([e e])
            (cond
              #,@(for/list ([pred? constructor-predicates]
                            [m method-names]
                            [args (attribute t.args)]
                            [rargs (attribute t.recursive-args)])
                   ;; TODO: Wouldn't it be better to statically generate the dereferencing of each field
                   ;; from the struct? This would also make it easy to place the recursive elimination.
                   ;; Can't do that easily, due to alpha-conversion; won't know the name of the
                   ;; field reference function
                   #`[(#,pred? e)
                      ;; TODO: Efficiency hack: use vector instead of list?
                      (let* ([args (drop (struct->list e) 'p)]
                             ;; TODO: Stub for recursive args
                             ;; apply loop to each recursive arg
                             ;; TODO: should these be lazy? tail recursive?
                             [recursive-args (for/list ([x args]
                                                        [i (in-naturals)]
                                                        [j '#,rargs]
                                                        #:when (eq? i j))
                                               (loop x))])
                        ;; NB: the method is curried, so ...
                        ;; TODO: Efficiency hack: attempt to uncurry elim methods?
                        ;; TODO: Abstract this as "curried-apply?"
                        (for/fold ([app #,m])
                                  ([a (append args recursive-args)])
                            (app a)))])))))]))

(define-syntax (cur-data syn)
  (syntax-parse syn
    #:datum-literals (:)
    [(_:top-level-id name:id : p:nat type:cur-typed-inductive-telescope (c-name:id : c-type) ...)
     #:do [(define number-of-constructors (length (attribute c-name)))
           (define elim-name (syntax-property (format-id syn "~a-elim" #'name) 'elim #t))
           (define params (syntax->datum #'p))
           (define is (build-list number-of-constructors values))]
     #:with (i ...) is
     #:with (a-name ...) (map (λ (n i)
                                (syntax-properties n
                                 `((constant . #t)
                                   (constructors-inductive . ,#'name)
                                   (params . ,params)
                                   (constructor-index . ,i))))
                              (attribute c-name)
                              is)
     #`(begin
         (cur-axiom #,(syntax-properties #'name
                       `((inductive . #t)
                         (constant . #t)
                         (constructors . ,(attribute a-name))
                         (number-of-constructors . ,number-of-constructors)
                         (params . ,params)
                         (elim-name . ,elim-name))) : type)
         (_cur-constructor a-name (name) : c-type) ...
         (_cur-elim #,elim-name name c-name ...))]))

(begin-for-syntax
  ;; corresponds to check-motive judgment in model
  (define (check-motive syn D params t_D t_motive)
    ;; Apply D and t_D to params
    (define-values (Dp t_Dp)
      (for/fold ([Dp D]
                 [t_Dp t_D])
                ([p params])
        (values
         ;; TODO: Why not use cur-app* and normalize?
         #`(#%plain-app #,Dp #,p)
         (syntax-parse t_Dp
           [e:reified-pi
            (subst p #'e.name #'e.body)]))))
    (let loop ([Dp Dp]
               [t_Dp t_Dp]
               [t_motive t_motive])
      (syntax-parse #`(#,Dp #,t_Dp #,t_motive)
        [(e e1:reified-universe ~! e2:reified-pi)
         #:with body:cur-typed-expr #'e2.body
         #:fail-unless (syntax-parse #'body [_:reified-universe #t] [_ #f])
         (raise-syntax-error
          'core-type-error
          (format "Expected result of motive to be a kind, but found something of type ~a."
                  ;; TODO: ad-hoc resugaring
                  (syntax->datum (cur-reflect #'body)))
          syn)
         (unless (cur-equal? #'e #'e2.type-ann)
           (raise-syntax-error
            'core-type-error
            (format "Expected final argument of motive to be the same type as the target, i.e. ~a, but found ~a."
                    #'e
                    #'e2.type-ann))
           syn)]
        [(e e1:reified-pi ~! e2:reified-pi)
         (loop #`(#%plain-app e e2.name) (subst #'e2.name #'e1.name #'e1.body) #'e2.body)]
        [_ (error 'check-motive "Something terrible has happened")])))

  ;; TODO: Check recursive arguments; not sure if they can be Ξ[(D e ...)]; see brady2005
  (define (check-method syn name n params motive method constr)
    (define/syntax-parse m:cur-typed-expr method)
    (define/syntax-parse c:cur-typed-expr (cur-app* constr params))
    (define/syntax-parse (~var c-tele (reified-constructor-telescope name)) #'c.type)
    (define rargs (attribute c-tele.recursive-args))
    (let loop ([c-type #'c.type]
               [m-type #'m.type]
               [i 0]
               [target #'c.erased]
               [recursive '()])
      (syntax-parse #`(#,c-type #,m-type)
        [(e1:reified-constant ~! e:reified-telescope)
         #:do [(define expected-return-type (cur-normalize (cur-app* motive `(,@(drop (attribute e1.args) n) ,target))))]
         #:do [(define return-type
                 (for/fold ([r #'e])
                           ([t (attribute e.anns)]
                            [rarg recursive])
                   ;; TODO: Recomputing some of the recurisve argument things...
                   (syntax-parse (cdr rarg)
                     [e:reified-constant
                      ;; TODO: append
                      #:with r-:reified-pi r
                      #:do [(define ih (cur-normalize (cur-app* motive (append (drop (attribute e.args) n)
                                                                               (list (car rarg))))))]
                      #:fail-unless (cur-equal? t ih)
                      (raise-syntax-error
                       'core-type-error
                       (format "Expected an inductive hypothesis equal to ~a, but found ~a."
                               ih
                               t)
                       syn
                       t)
                      #'r-.body])))]
         #:fail-unless (cur-equal? return-type expected-return-type)
         (raise-syntax-error
          'core-type-error
          ;; TODO: Resugar
          (format "Expected method to return type ~a, but found return type of ~a"
                  (syntax->datum expected-return-type)
                  (syntax->datum return-type))
          syn)
         (void)]
        [(e1:reified-pi ~! e2:reified-pi)
         ;; TODO: Subtypes? No, I think equal types, since argument.
         #:fail-unless (cur-equal? #'e1.type-ann #'e2.type-ann)
         (raise-syntax-error
          'core-type-error
          (format "Expected ~ath method argument to have type ~a, but found type ~a"
                  i
                  #'e1.type-ann
                  #'e2.type-ann)
          syn)
         (loop #'e1.body (subst #'e1.name #'e2.name #'e2.body) (add1 i) #`(cur-app #,target e1.name)
               (if (memq i rargs)
                   (cons (cons #'e1.name #'e1.type-ann) recursive)
                   recursive))])))

  )

;; TODO: Type check methods.
;; TODO: Rewrite and abstract this code omg
(define-syntax (cur-elim syn)
  (syntax-parse syn
    #:datum-literals (:)
    [(_ e:cur-typed-expr motive:cur-procedure (method:cur-typed-expr ...))
     ;; TODO: Some attributes should be definitions
     #:with e-type #'e.type
     #:declare e-type cur-typed-expr
     #:fail-unless (syntax-parse #'e-type.type
                     [_:reified-universe #t]
                     [_ #f])
     (cur-type-error
      syn
      "target to be a fully applied inductive type"
      "found target ~a"
      "~a, which accepts more arguments"
      (syntax->datum #'e)
      (syntax->datum #'e.type))
     #:fail-unless (syntax-parse #'e-type.erased
                     [e:reified-constant
                      (syntax-property #'e.constr 'inductive)]
                     [_ #f])
     (cur-type-error
      syn
      ;; TODO: Maybe check if axiom and report that? Might be easy to confuse axiom and inductive.
      "target to inhabit an inductive type"
      (syntax->datum #'e)
      (syntax->datum (car (syntax-property (attribute e.type) 'origin))))
     #:with D #'e-type.erased
     #:declare D reified-constant
     #:do [(define name #'D.constr)
           (define params (syntax-property name 'params))
           (define indices (drop (attribute D.args) params))]
     #:with elim-name (syntax-property name 'elim-name)
     #:with n:cur-typed-expr name
     #:do [(check-motive #'motive name (take (attribute D.args) params) #'n.type #'motive.type)]
     #:do [(for ([m (attribute method.erased)]
                 [c (syntax-property name 'constructors)])
             (check-method syn name params (take (attribute D.args) params) #'motive.erased m c))]
     #:attr number-of-constructors (syntax-property name 'number-of-constructors)
     #:fail-unless (= (attribute number-of-constructors) (length (attribute method)))
     (raise-syntax-error 'core-type-error
                         (format "Expected one method for each constructor, but found ~a constructors and ~a branches."
                                 (attribute number-of-constructors)
                                 (length (attribute method)))
                         syn)
     ;; TODO: Maybe set-type should normalize, reflect, then set?
     ;; TODO: That seems to cause an infinite loop
     (⊢ (elim-name e.erased motive.erased method.erased ...) :
        #,(cur-reflect (cur-normalize (cur-app* #'motive.erased (append indices (list #'e.erased))))))]))