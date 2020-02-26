(* Elaboration from D<:> with full terms as paths into a simpler CC-style
   dependently typed system without type bounds.

   The current version does not have an explicit subtyping judgement but
   includes intro and elim forms for e.T types as part of the type
   assignment for terms (has_type).
*)


(*
  Source language (currently missing: T ::=  T1 /\ T2 | { z => T^z }):

  DSubSup (D<:>)
  T ::= Top | Bot | t.Type | { Type: S..U } | (z: T) -> T^z
  t ::= x | { Type = T } | lambda x:T.t | t t

  Target language (inspired by https://docs.racket-lang.org/pie/index.html):

  t ::= x | Unit | Type
      | (z: T) -> T^z  | lambda x:T.t | t t
      | Sigma z:T. T^z | (t, t)  | fst t | snd t

  Translation (with syntactic sugar ->/* for non-dependent fun/pair):

  [[ t.Type ]]         = fst [[ t ]]
  [[ { Type: S..U } ]] = Sigma T:Type. ([[ S ]] -> T) * (T -> [[ U ]])

  [[ { Type = T } ]]   = (T, ((lambda x:T. x), (lambda x:T. x)))

*)

(*
  Roadmap:

  Frontend:
    - finish proof of type-preserving translation (esp. binding/subst for dep elim)
    - add intersection and recursive types to source (term-based elim/intro)
    - add subtyping relation
    - introduce rec capabilities and translate to term/nonterm based on context

  Backend (mainly follow Zombie paper POPL14):
    - prove termination of target
    - distinguish terminating/non-terminating fragment

*)


Require Export Arith.EqNat.
Require Export Arith.Le.
Require Import Coq.Program.Equality.
Require Import Omega.
Require Import Coq.Lists.List.
Import ListNotations.

(* ### Syntax ### *)

Definition id := nat.

(* term variables occurring in types *)
Inductive var : Type :=
| varF : id -> var (* free, in concrete environment *)
| varB : id -> var (* locally-bound variable *)
.

Inductive ty : Type :=
| TTop : ty
| TBot : ty
(* (z: T) -> T^z *)
| TAll : ty -> ty -> ty
(* We generalize x.Type to tm.type for arbitrary terms tm.  *)
| TSel : tm -> ty
(* { Type: S..U } *)
| TMem : ty(*S*) -> ty(*U*) -> ty
| TBind  : ty -> ty (* Recursive binder: { z => T^z },
                         where z is locally bound in T *)
| TAnd : ty -> ty -> ty (* Intersection Type: T1 /\ T2 *)


with tm : Type :=
(* x -- free variable, matching concrete environment *)
| tvar : var -> tm
(* { Type = T } *)
| ttyp : ty -> tm
(* lambda x:T.t *)
| tabs : ty -> tm -> tm
(* t t *)
| tapp : tm -> tm -> tm
(* unpack(e) { x => ... } *)
| tunpack : tm -> tm -> tm
.

Inductive vl : Type :=
(* a closure for a lambda abstraction *)
| vabs : list vl (*H*) -> ty -> tm -> vl
(* a closure for a first-class type *)
| vty : list vl (*H*) -> ty -> vl
.

Definition tenv := list ty. (* Gamma environment: static *)
Definition venv := list vl. (* H environment: run-time *)


(* ### Representation of Bindings ### *)

(* An environment is a list of values, indexed by decrementing ids. *)

Fixpoint indexr {X : Type} (n : id) (l : list X) : option X :=
  match l with
    | [] => None
    | a :: l' =>
      if (beq_nat n (length l')) then Some a else indexr n l'
  end.

Inductive closed: nat(*B*) -> nat(*F*) -> ty -> Prop :=
| cl_top: forall i j,
    closed i j TTop
| cl_bot: forall i j,
    closed i j TBot
| cl_all: forall i j T1 T2,
    closed i j T1 ->
    closed (S i) j T2 ->
    closed i j (TAll T1 T2)
(* Now we have mutually recursive definitions for closedness on types and terms! *)
| cl_sel_tm: forall i j t,
    closed_tm i j t ->
    closed i j (TSel t)
| cl_mem: forall i j T1 T2,
    closed i j T1 ->
    closed i j T2 ->
    closed i j (TMem T1 T2)
| cl_bind: forall i j T,
    closed (S i) j T ->
    closed i j (TBind T)
| cl_and: forall i j T1 T2,
    closed i j T1 ->
    closed i j T2 ->
    closed i j (TAnd T1 T2)


with closed_tm: nat(*B*) -> nat(*F*) -> tm -> Prop :=
| cl_tvarb: forall i j x,
    i > x ->
    closed_tm i j (tvar (varB x))
| cl_tvarf: forall i j x,
    j > x ->
    closed_tm i j (tvar (varF x))
| cl_ttyp:  forall i j ty,
    closed i j ty ->
    closed_tm i j (ttyp ty)
| cl_tabs:  forall i j ty tm,
    closed i j ty ->
    closed_tm (S i) j tm ->
    closed_tm i j (tabs ty tm)
| cl_tapp:  forall i j tm1 tm2,
    closed_tm i j tm1 ->
    closed_tm i j tm2 ->
    closed_tm i j (tapp tm1 tm2)
| cl_tunpack: forall i j tm1 tm2,
    closed_tm i j tm1 ->
    closed_tm (S i) j tm2 ->
    closed_tm i j (tunpack tm1 tm2)
.

(* open define a locally-nameless encoding wrt to TVarB type variables. *)
(* substitute var u for all occurrences of (varB k) *)
Fixpoint open_rec (k: nat) (u: var) (T: ty) { struct T }: ty :=
  match T with
    | TTop        => TTop
    | TBot        => TBot
    | TAll T1 T2  => TAll (open_rec k u T1) (open_rec (S k) u T2)
    | TSel tm => TSel (open_rec_tm k u tm)
    | TMem T1 T2  => TMem (open_rec k u T1) (open_rec k u T2)
    | TBind T => TBind (open_rec (S k) u T)
    | TAnd T1 T2 => TAnd (open_rec k u T1) (open_rec k u T2)
  end

with open_rec_tm (k: nat) (u: var) (t: tm) { struct t }: tm :=
       match t with
       | tvar (varF x) => tvar (varF x)
       | tvar (varB x) =>
         if beq_nat k x then (tvar u) else (tvar (varB x))
       | ttyp ty => ttyp (open_rec k u ty)
       | tabs ty tm => tabs (open_rec k u ty) (open_rec_tm (S k) u tm)
       | tapp tm1 tm2 => tapp (open_rec_tm k u tm1) (open_rec_tm k u tm2)
       | tunpack tm1 tm2 => tunpack (open_rec_tm k u tm1) (open_rec_tm (S k) u tm2)
       end.

Definition open u T := open_rec 0 u T.
Definition open_tm u t := open_rec_tm 0 u t.

(* ### Type Assignment ### *)
Inductive is_type: tenv -> ty -> Set :=
| t_top: forall G, is_type G TTop
| t_bot: forall G, is_type G TBot
| t_mem: forall G T1 T2, is_type G T1 -> is_type G T2 -> is_type G (TMem T1 T2)
| t_all: forall G T1 T2,
    is_type G T1 ->
    is_type (T1::G) (open (varF (length G)) T2) ->
    is_type G (TAll T1 T2)
| t_sel: forall G e T1 T2,
    is_type G T1 -> (* redundant, but needed for induction(?) *)
    is_type G T2 ->
    has_type G e (TMem T1 T2) ->
    is_type G (TSel e)

with has_type : tenv -> tm -> ty -> Set :=
| t_var: forall x env T1,
           indexr x env = Some T1 ->
           is_type env T1 ->
           has_type env (tvar (varF x)) T1

(*
(* pack a recursive type  *)
| t_var_pack : forall G1 x T1 T1',
           (* has_type G1 (tvar x) T1' -> *)
           indexr x G1 = Some (open (varF x) T1) ->
           T1' = (open (varF x) T1) ->
           closed 1 0 (length G1) T1 ->
           has_type G1 (tvar (varF x)) (TBind T1)
(* unpack a recursive type: unpack(x:{z=>T^z}) { x:T^x => ... }  *)
| t_unpack: forall env x y T1 T1' T2,
           has_type env x (TBind T1) ->
           T1' = (open (varF (length env)) T1) ->
           has_type (T1'::env) y T2 ->
           closed 0 0 (length env) T2 ->
           has_type env (tunpack x y) T2
 *)

(* type selection intro and elim forms *)
| t_sel2: forall env e a T1,
          has_type env a T1 ->
          has_type env e (TMem T1 TTop) ->
          has_type env a (TSel e)

| t_sel1: forall env e a T1,
          has_type env a (TSel e) ->
          has_type env e (TMem TBot T1) ->
          has_type env a T1


(* intersection typing *)
(*
| t_and : forall env x T1 T2,
           has_type env (tvar x) T1 ->
           has_type env (tvar x) T2 ->
           has_type env (tvar x) (TAnd T1 T2)
*)

| t_typ: forall env T1,
           is_type env T1 ->
           has_type env (ttyp T1) (TMem T1 T1)

| t_app: forall env f x T1 T2,
           has_type env f (TAll T1 T2) ->
           has_type env x T1 ->
           closed 0 (length env) T2 -> (* TODO: dependent app! *)
           has_type env (tapp f x) T2
(*
| t_dapp:forall env f x T1 T2 T,
           has_type env f (TAll T1 T2) ->
           has_type env (tvar (varF x)) T1 ->
           T = open (varF x) T2 ->
           closed 0 0 (length env) T ->
           has_type env (tapp f (tvar (varF x))) T
*)
| t_abs: forall env y T1 T2,
           is_type env T1 ->
           has_type (T1::env) y (open (varF (length env)) T2) ->
           has_type env (tabs T1 y) (TAll T1 T2)
(*
| t_sub: forall env e T1 T2,
           has_type env e T1 ->
           stp env [] T1 T2 ->
           has_type env e T2
*)
.



Module F.

Inductive kind : Type :=
| Box :  kind
| Star : kind
.

Inductive tm : Type := (* TODO what about equality types? *)
| Kind : kind -> tm
| TTop : tm (* TODO really needed? *)
| TBot : tm (* TODO really needed? *)
| TAll : tm -> tm -> tm
| TSig : tm -> tm -> tm
| tvar : var -> tm
| tabs : tm -> tm -> tm
| tapp : tm -> tm -> tm
| tsig : tm -> tm -> tm
| tfst : tm -> tm
| tsnd : tm -> tm
.

(* \square *)
Notation "◻" := (Kind Box).
(* \star *)
Notation "⋆" := (Kind Star).

Definition tenv := list tm.

(*TODO: is it ok if we generalize opening w. arbitrary terms? *)
Fixpoint open_rec (k: nat) (u: tm) (T: tm) { struct T }: tm :=
  match T with
  | ⋆           => ⋆
  | ◻           => ◻
  | TTop        => TTop
  | TBot        => TBot
  | TAll T1 T2  => TAll (open_rec k u T1) (open_rec (S k) u T2)
  | TSig T1 T2  => TSig (open_rec k u T1) (open_rec (S k) u T2)
  | tvar (varF x) => tvar (varF x)
  | tvar (varB x) =>
    if beq_nat k x then u else (tvar (varB x))
  | tabs ty tm => tabs (open_rec k u ty) (open_rec (S k) u tm)
  | tapp tm1 tm2 => tapp (open_rec k u tm1) (open_rec k u tm2)
  | tsig tm1 tm2 => tsig (open_rec k u tm1) (open_rec (S k) u tm2)
  | tfst tm => tfst (open_rec k u tm)
  | tsnd tm => tsnd (open_rec k u tm)
  end.

Definition open u T := open_rec 0 (tvar u) T.
Definition open' t T := open_rec 0 t T.

Inductive tenv_wf: tenv -> Prop :=
| tenv_wf_empty:
    tenv_wf []

| tenv_wf_kind: forall Gamma T U,
    tenv_wf Gamma ->
    has_type Gamma T (Kind U) ->
    tenv_wf (T :: Gamma)

with has_type : tenv -> tm -> tm -> Prop :=
| t_box: forall Gamma,
    has_type Gamma ⋆ ◻

| t_var: forall x Gamma T,
    tenv_wf Gamma ->
    indexr x Gamma = Some T ->
    has_type Gamma (tvar (varF x)) T

| t_allt: forall Gamma T1 T2 U U',
    has_type Gamma T1 (Kind U) -> (* not strictly necessary  *)
    has_type (T1 :: Gamma) (open (varF (length Gamma)) T2) (Kind U') ->
    has_type Gamma (TAll T1 T2) (Kind U') (* TODO is U' = Box needed at all? *)

| t_sigt: forall Gamma T1 T2 U U',
    (* TODO this leads to logical inconsistency,
       should fix U to ⋆, or try infinite hierarchy of kinds
       (cf. Luo's ECC resp. LEGO system). Arthur's libln model of CC shows how to model hierarchy in Coq) *)
    has_type Gamma T1 (Kind U) -> (* not strictly necessary here*)
    has_type (T1 :: Gamma) (open (varF (length Gamma)) T2) (Kind U') ->
    has_type Gamma (TSig T1 T2) (Kind U') (* TODO is U' = Box needed at all? *)

| t_topt: forall Gamma,
    has_type Gamma TTop ⋆

| t_bott: forall Gamma,
    has_type Gamma TBot ⋆

| t_abs: forall Gamma t T1 T2 U U',
    has_type Gamma T1 (Kind U) -> (* not strictly necessary *)
    has_type Gamma (TAll T1 T2) (Kind U') ->
    has_type (T1 :: Gamma) t (open (varF (length Gamma)) T2) ->
    has_type Gamma (tabs T1 t) (TAll T1 T2)

| t_app: forall Gamma f e T1 T2 T,
    has_type Gamma f (TAll T1 T2) ->
    has_type Gamma e T1 ->
    T = (open' e T2) ->
    has_type Gamma (tapp f e) T

| t_sig: forall Gamma e1 e2 T1 T2,
    has_type Gamma e1 T1 ->
    has_type Gamma e2 (open' e1 T2) ->
    has_type Gamma (tsig e1 e1) (TSig T1 T2) (* TODO: type annotation required? *)

| t_fst: forall Gamma e T1 T2,
    has_type Gamma e (TSig T1 T2) ->
    has_type Gamma (tfst e) T1

| t_snd: forall Gamma e T1 T2 T,
    has_type Gamma e (TSig T1 T2) ->
    T = (open' (tfst e) T2) ->
    has_type Gamma (tsnd e) T
.

(* TODO: move module to separate file *)
(* TODO: define reduction/evaluation *)
(* TODO: define strong normalization *)

End F.

Fixpoint ttp G T (ty: is_type G T): F.tm :=
  match ty with
  | t_top _ => F.TTop
  | t_bot _ => F.TBot
  | t_all _ _ _ T1 T2 => F.TAll (ttp _ _ T1) (ttp _ _ T2)
  | t_mem _ _ _ T1 T2 =>
    let f1 := F.TAll (ttp _ _ T1) (F.tvar (varB 1)) in
    let f2 := F.TAll (F.tvar (varB 2)) (ttp _ _ T2) in
    F.TSig F.Star (F.TSig f1 f2) (* XXX check *)
  | t_sel _ _ _ _ _ _ e => F.tfst (ttm _ _ _ e)
  end
with ttm G e T (tm: has_type G e T): F.tm :=
  match tm with
  | t_var v _ _ _ _ => F.tvar (varF v)
  | t_typ _ _ T1 =>
    let T1' := (ttp _ _ T1) in
    let idfun := (F.tabs T1' (F.tvar (varF (length G)))) in
    F.tsig T1' (F.tsig idfun idfun)
  | t_sel2 _ _ _ _ T1 TM  => F.tapp (F.tfst (F.tsnd (ttm _ _ _ TM))) (ttm _ _ _ T1)
  | t_sel1 _ _ _ _ T1 TM  => F.tapp (F.tsnd (F.tsnd (ttm _ _ _ TM))) (ttm _ _ _ T1)
  | t_app _ _ _ _ _ T1 T2 _ => F.tapp (ttm _ _ _ T1) (ttm _ _ _ T2)
  | t_abs _ _ _ _ T1 T2 => F.tapp (ttp _ _ T1) (ttm _ _ _ T2)
  end.


(* TODO: dependent app isn't correctly defined right now, so we need this crutch *)
Lemma shotgun1: forall env T1 T2,
    is_type (T1 :: env) (open (varF (length env)) T2) ->
    is_type env T2.
Admitted.
Lemma shotgun2: forall env e T1 T2,
    F.has_type env e T2 ->
    F.has_type ((T1, F.Star) :: env) (F.open_rec 0 (varF (length env)) e) T2.
Admitted.


Lemma extract1: forall G T1 T2, is_type G (TMem T1 T2) -> is_type G T2.
Proof.
  intros. inversion H. eauto.
Qed.
Lemma extract2: forall G T1 T2, is_type G (TAll T1 T2) -> is_type (T1::G) (open (varF (length G)) T2).
Proof.
  intros. inversion H. eauto.
Qed.

(* if term has a type, the type is well-formed *)
Fixpoint htwf G e T (tm: has_type G e T): is_type G T :=
  match tm with
  | t_var _ _ _ _ i => i
  | t_sel2 _ _ _ _ h1 h2 => t_sel _ _ _ _ (htwf _ _ _ h1) (t_top _) h2
  | t_sel1 _ _ _ _ h1 h2 => extract1 _ _ _ (htwf _ _ _ h2)
  | t_typ _ _ i => t_mem _ _ _ i i
  | t_app _ _ _ _ _ h1 _ _ => shotgun1 _ _ _ (extract2 _ _ _ ((htwf _ _ _ h1)))
  | t_abs _ _ _ _ i h => t_all _ _ _ i (htwf _ _ _ h)
  end.



Lemma indexr_lookup_max: forall T (G1:list T) a,
    indexr (length G1) (a :: G1) = Some a.
Proof.
Admitted.

(* todo: is_type has a canonical form *)
Lemma foobar: forall G T1 T2 i1 i2 e h, htwf G e (TMem T1 T2) h = t_mem G _ _ i1 i2.
Proof.
Admitted.


(* Theorem: translation is well-typed *)
(* todo: need an env predicate to relate G and G1 *)
Theorem ttpok:
  forall G T (IT: is_type G T), forall G1, F.has_type G1 (ttp _ _ IT) F.Star.
Proof.
  apply (is_type_ind_mut (* TODO this is not defined yet *)
           (fun G T IT => forall G1, F.has_type G1 (ttp _ _ IT) F.Star)
           (fun G e T HT => forall G1, F.has_type G1 (ttm _ _ _ HT) (ttp _ _ (htwf _ _ _ HT)))).

  - (* TTop *) econstructor.

  - (* TBot *) econstructor.

  - (* TMem T1 T2  ->  \Sigma TX: Type. (T1' -> TX) * (TX -> T2') *)
    intros. simpl. eapply F.t_sigt. econstructor.
    unfold F.open. simpl. eapply F.t_sigt. econstructor. eapply shotgun2. eauto.
    eapply shotgun2. eapply F.t_var. eapply indexr_lookup_max. econstructor.
    unfold F.open. simpl. eapply F.t_all.
    admit. admit. (* boring but tedious, need to get all open/subst right *)

  - (* TAll *) intros. simpl. econstructor. eauto. unfold F.open. simpl. admit. (* open mismatch *)

  - (* TSel e  ->  fst e' *)
    (* we know e: *)
    (* e: TMem T1 T2  ->  e': \Sigma ... *)
    intros. simpl.

    rewrite (foobar _ _ _ i i0) in H1. simpl in H1.
    eapply F.t_fst. eapply H1.

  - (* t_var *) intros. econstructor.
    admit. (* indexr *)
    eapply H.

  - (* t_sel2 *)
    (* apply first conversion function *)
    intros. simpl.

    rewrite (foobar _ _ _ (htwf _ _ _ h) (t_top _)) in H0. simpl in H0.

    eapply F.t_app. eapply F.t_fst. eapply F.t_snd. eapply H0. eapply H.

  - (* t_sel1 *)
    (* apply second conversion function *)
    intros. simpl.

    assert (is_type env T1) as i0. admit. (* from htwf *)

    rewrite (foobar _ _ _ (t_bot _) i0) in H0. simpl in H0.

    eapply F.t_app. eapply F.t_snd. eapply F.t_snd. eapply H0.

    (* FIXME: function arg -- need correct type: fst of triple *)
    admit.

  - (* t_typ *)
    admit.

  - (* t_app *)
    admit.

  - (* t_abs *)
    admit.

Admitted.
