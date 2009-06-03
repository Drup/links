open Utility
open Types
open Typevarcheck

(* debug flags *)
let show_unification = Settings.add_bool("show_unification", false, `User)
let show_row_unification = Settings.add_bool("show_row_unification", false, `User)
let show_recursion = Instantiate.show_recursion

let rigid_type_variables = Settings.add_bool("rigid_type_variables", true, `User)
(*
  what kind of recursive types to allow
  "all"      - allow all recursive types
  "guarded"  - only allow guarded recursive types
  "positive" - only allow positive recursive types
 *)
let infer_recursive_types = Settings.add_string("infer_recursive_types", "guarded", `User)

type error = [
  `Msg of string
| `PresentAbsentClash of string * Types.row * Types.row
]

exception Failure of error

let occurs_check var t =
  match Settings.get_value infer_recursive_types with
    | "all" -> true
    | "guarded" -> is_guarded var t
    | "positive" -> not (is_negative var t)
    | s -> failwith ("user setting infer_recursive_types ("^ s ^") must be set to 'all', 'guarded' or 'positive'")

let occurs_check_row var row =
  match Settings.get_value infer_recursive_types with
    | "all" -> true
    | "guarded" -> is_guarded_row var row
    | "positive" -> not (is_negative_row var row)
    | s -> failwith ("user setting infer_recursive_types ("^ s ^") must be set to 'all', 'guarded' or 'positive'")

let var_is_free_in_type var datatype = TypeVarSet.mem var (free_type_vars datatype)

(* a special kind of structural equality on types that doesn't look
inside points *)
let rec eq_types : (datatype * datatype) -> bool =
  fun (t1, t2) ->
    let rec unalias = function
      | `Alias (_, x) -> unalias x
      | x             -> x in
    match unalias t1 with 
      | `Not_typed -> 
          begin match unalias t2 with
              `Not_typed -> true
            | _          -> false
          end
      | `Primitive x ->
          begin match unalias t2 with
              `Primitive y -> x = y
            | _            -> false
          end
      | `MetaTypeVar lpoint ->
          begin match unalias t2 with
              `MetaTypeVar rpoint -> Unionfind.equivalent lpoint rpoint
            | _                   -> false
          end
      | `Function (lfrom, lm, lto) ->
          begin match unalias t2 with
              `Function (rfrom, rm, rto) -> eq_types (lfrom, rfrom)
                                         && eq_types (lto,   rto)
                                         && eq_rows  (lm,    rm)
            | _                          -> false
          end
      | `Record l ->
          begin match unalias t2 with
              `Record r -> eq_rows (l, r)
            | _         -> false
          end
      | `Variant l ->
          begin match unalias t2 with
              `Variant r -> eq_rows (l, r)
            | _          -> false
          end
      | `Application (s, ts) ->
          begin match unalias t2 with
              `Application (s', ts') -> s = s' && List.for_all2 (Utility.curry eq_type_args) ts ts'
            | _ -> false
          end
      | `Alias  _ -> assert false
      | `ForAll _ -> assert false
      | `Table _  -> assert false
and eq_rows : (row * row) -> bool =
  fun ((lfield_env, lrow_var), (rfield_env, rrow_var)) ->
    eq_field_envs (lfield_env, rfield_env) && eq_row_vars (lrow_var, rrow_var)
and eq_presence =
  function
    | `Absent, `Absent
    | `Present, `Present -> true
    | `Var lpoint, `Var rpoint -> Unionfind.equivalent lpoint rpoint
and eq_field_envs (lfield_env, rfield_env) =
  let eq_specs (lf, lt) (rf, rt) = eq_presence (lf, rf) && eq_types (lt, rt) in
    StringMap.equal eq_specs lfield_env rfield_env
and eq_row_vars (lpoint, rpoint) =
  (* QUESTION:
     Do we need to deal with closed rows specially?
  *)
  match Unionfind.find lpoint, Unionfind.find rpoint with
    | `Closed, `Closed -> true
    | `Flexible (var, _), `Flexible (var', _)
    | `Rigid (var, _), `Rigid (var', _)
    | `Recursive (var, _), `Recursive (var', _) -> var=var'
    | _, _ -> Unionfind.equivalent lpoint rpoint
and eq_type_args =
  function
    | `Type lt, `Type rt -> eq_types (lt, rt)
    | `Row lr, `Row rr -> eq_rows (lr, rr)
    | `Presence lf, `Presence rf -> eq_presence (lf, rf)
    | _, _ -> false

(*
  unification environment:
    for stopping cycles during unification
*)
type unify_type_env = (datatype list) IntMap.t
type unify_row_env = (row list) IntMap.t
type unify_env = unify_type_env * unify_row_env

let rec unify' : unify_env -> (datatype * datatype) -> unit = fun rec_env ->
  let rec_types, rec_rows = rec_env in

  let is_unguarded_recursive t =
    let rec is_unguarded rec_types t = 
      match t with
        | `MetaTypeVar point ->
            begin
              match (Unionfind.find point) with
                | `Recursive (var, body) when IntSet.mem var rec_types -> true
                | `Recursive (var, body) -> is_unguarded (IntSet.add var rec_types) body
                | `Body t -> is_unguarded rec_types t
                | _ -> false
            end
        |  _ -> false
    in
      is_unguarded IntSet.empty t in
    
  let unify_rec ((var, body), t) =
    let ts =
      if IntMap.mem var rec_types then
        IntMap.find var rec_types
      else
        [body]
    in
      (* break cycles *)
      if List.exists (fun t' -> eq_types (t, t')) ts then
        ()
      else
        unify' (IntMap.add var (t::ts) rec_types, rec_rows) (body, t) in

  let unify_rec2 ((lvar, lbody), (rvar, rbody)) =
    let lts =
      if IntMap.mem lvar rec_types then
        IntMap.find lvar rec_types
      else
        [lbody] in
      
    let rts =
      if IntMap.mem rvar rec_types then
        IntMap.find rvar rec_types
      else
        [rbody]
    in
      (* break cycles *)
      if (List.exists (fun t -> eq_types (t, rbody)) lts
       || List.exists (fun t -> eq_types (t, lbody)) rts) then
        ()
      else
        unify' ((IntMap.add lvar (rbody::lts) ->- IntMap.add rvar (lbody::rts)) rec_types, rec_rows) (lbody, rbody) in

  (* introduce a recursive type
     give an error if it is non-well-founded and
     non-well-founded type inference is switched off

     preconditions:
     - Unionfind.find point = t
     - var is free in t
  *)
  let rec_intro point (var, t) =
    if occurs_check var t then
      Unionfind.change point (`Recursive (var, t))
    else
      raise (Failure (`Msg ("Cannot unify type variable "^string_of_int var^" with datatype "^string_of_datatype t^
                              " because "^
                              match Settings.get_value infer_recursive_types with
                                | "guarded" -> "the type variable occurs unguarded inside the datatype"
                                | "positive" -> "the type variable occurs in a negative position inside the datatype"
                                | _ -> assert false))) in

    fun (t1, t2) ->
      (Debug.if_set (show_unification) (fun () -> "Unifying "^string_of_datatype t1^" with "^string_of_datatype t2);
       (match (t1, t2) with
          | `Not_typed, _ | _, `Not_typed -> failwith "Internal error: `Not_typed' passed to `unify'"
          | `Primitive x, `Primitive y when x = y -> ()
          | `MetaTypeVar lpoint, `MetaTypeVar rpoint ->
              if Unionfind.equivalent lpoint rpoint then
                ()
              else
                (match (Unionfind.find lpoint, Unionfind.find rpoint) with
                   | `Rigid (l, _), `Rigid (r, _) ->
                       if l <> r then 
                         raise (Failure (`Msg ("Rigid type variables "^ string_of_int l ^" and "^ string_of_int r ^" do not match")))
                       else
                         (* presumably this should always be a no-op *)
                         Unionfind.union lpoint rpoint
                   | `Flexible (_, lkind), `Flexible (rvar, rkind) ->
                       Unionfind.union lpoint rpoint;
                       begin
                         match lkind, rkind with
                           | `Base, `Any ->
                               Unionfind.change rpoint (`Flexible (rvar, `Base))
                           | _ -> ()
                       end
                   | `Flexible (var, subkind), _ ->
                       (if var_is_free_in_type var t2 then
                          (Debug.if_set (show_recursion) (fun () -> "rec intro1 (" ^ (string_of_int var) ^ ")");
                           if subkind = `Base then
                             raise (Failure (`Msg ("Cannot infer a recursive type for the type variable "^ string_of_int var ^
                                                     " with the body "^ string_of_datatype t2)));
                           rec_intro rpoint (var, Types.concrete_type t2))
                        else
                          ());
                       if subkind = `Base then
                         if Types.is_baseable_type t2 then
                           Types.basify_type t2
                         else
                           raise (Failure (`Msg ("Cannot unify the base type variable "^ string_of_int var ^
                                                   " with the non-base type "^ string_of_datatype t2)));
                       Unionfind.union lpoint rpoint
                   | _, `Flexible (var, subkind) ->
                       (if var_is_free_in_type var t1 then
                          (Debug.if_set (show_recursion) (fun () -> "rec intro2 (" ^ (string_of_int var) ^ ")");
                           if subkind = `Base then
                             raise (Failure (`Msg ("Cannot infer a recursive type for the type variable "^ string_of_int var ^
                                                     " with the body "^ string_of_datatype t1)));
                           rec_intro lpoint (var, Types.concrete_type t1))
                        else
                          ());
                       if subkind = `Base then
                         if Types.is_baseable_type t1 then
                           Types.basify_type t1
                         else
                           raise (Failure (`Msg ("Cannot unify the base type variable "^ string_of_int var ^
                                                   " with the non-base type "^ string_of_datatype t1)));
                       Unionfind.union rpoint lpoint
                   | `Rigid (l, _), _ ->
                       raise (Failure (`Msg ("Couldn't unify the rigid type variable "^
                                               string_of_int l ^" with the type "^ string_of_datatype (`MetaTypeVar rpoint))))
                   | _, `Rigid (r, _) ->
                       raise (Failure (`Msg ("Couldn't unify the rigid type variable "^
                                               string_of_int r ^" with the type "^ string_of_datatype (`MetaTypeVar lpoint))))
                   | `Recursive (lvar, t), `Recursive (rvar, t') ->
                       assert (lvar <> rvar);
                       Debug.if_set (show_recursion)
                         (fun () -> "rec pair (" ^ (string_of_int lvar) ^ "," ^ (string_of_int rvar) ^")");
                       begin
                         if is_unguarded_recursive (`MetaTypeVar lpoint) then
                           begin
                             if not (is_unguarded_recursive (`MetaTypeVar rpoint)) then
                               raise (Failure (`Msg ("Couldn't unify the unguarded recursive type "^
                                                       string_of_datatype (`MetaTypeVar lpoint) ^
                                                       " with the guarded recursive type "^ string_of_datatype (`MetaTypeVar rpoint))))
                           end
                         else if is_unguarded_recursive (`MetaTypeVar lpoint) then
                           raise (Failure (`Msg ("Couldn't unify the unguarded recursive type "^
                                                   string_of_datatype (`MetaTypeVar rpoint) ^
                                                   " with the guarded recursive type "^ string_of_datatype (`MetaTypeVar lpoint))))
                         else
                           unify_rec2 ((lvar, t), (rvar, t'))
                       end;
                       Unionfind.union lpoint rpoint
                   | `Recursive (var, t'), `Body t ->
                       Debug.if_set (show_recursion) (fun () -> "rec left (" ^ (string_of_int var) ^ ")");
                       begin
                         if is_unguarded_recursive (`MetaTypeVar lpoint) then
                           raise (Failure (`Msg ("Couldn't unify the unguarded recursive type "^
                                                   string_of_datatype (`MetaTypeVar lpoint) ^
                                                   " with the non-recursive type "^ string_of_datatype (`MetaTypeVar rpoint))))
                         else                   
                           unify_rec ((var, t'), t)
                       end;
                       Unionfind.union rpoint lpoint
                   | `Body t, `Recursive (var, t') ->
                       Debug.if_set (show_recursion) (fun () -> "rec right (" ^ (string_of_int var) ^ ")");
                       begin
                         if is_unguarded_recursive (`MetaTypeVar rpoint) then
                           raise (Failure (`Msg ("Couldn't unify the unguarded recursive type "^
                                                   string_of_datatype (`MetaTypeVar rpoint) ^
                                                   " with the non-recursive type "^ string_of_datatype (`MetaTypeVar lpoint))))
                         else                   
                           unify_rec ((var, t'), t)
                       end;
                       Unionfind.union lpoint rpoint
                   | `Body t, `Body t' -> unify' rec_env (t, t'); Unionfind.union lpoint rpoint)
          | `MetaTypeVar point, t | t, `MetaTypeVar point ->
              (match (Unionfind.find point) with
                 | `Rigid (l, _) -> 
                     raise (Failure (`Msg ("Couldn't unify the rigid type variable "^ string_of_int l ^" with the type "^ string_of_datatype t)))
                 | `Flexible (var, subkind) ->
                     if var_is_free_in_type var t then
                       begin
                         Debug.if_set (show_recursion)
                           (fun () -> "rec intro3 ("^string_of_int var^","^string_of_datatype t^")");
                         if subkind = `Base then
                           raise (Failure (`Msg ("Cannot infer a recursive type for the type variable "^ string_of_int var ^
                                                   " with the body "^ string_of_datatype t)));
                         let point' = Unionfind.fresh (`Body t)
                         in
                           rec_intro point' (var, t);
                           Unionfind.union point point'
                       end
                     else
                       (Debug.if_set (show_recursion) (fun () -> "non-rec intro (" ^ string_of_int var ^ ")");
                        if subkind = `Base then
                          if Types.is_baseable_type t then
                            Types.basify_type t
                          else
                            raise (Failure (`Msg ("Cannot unify the base type variable "^ string_of_int var ^
                                                    " with the non-base type "^ string_of_datatype t)));
                        Unionfind.change point (`Body t))
                 | `Recursive (var, t') ->
                     Debug.if_set (show_recursion) (fun () -> "rec single (" ^ (string_of_int var) ^ ")");
                     begin
                       if is_unguarded_recursive (`MetaTypeVar point) then
                         raise (Failure (`Msg ("Couldn't unify the unguarded recursive type "^
                                                 string_of_datatype (`MetaTypeVar point) ^
                                                 " with the non-recursive type "^ string_of_datatype t)))
                       else                   
                         unify_rec ((var, t'), t)
                     end
                       (* It's tempting to try to do this, but it isn't sound
                          as point may appear inside t
                          
                          Unionfind.change point t;
                       *)
                 | `Body t' -> unify' rec_env (t, t'))
          | `Alias (_, t1), t2 
          | t1, `Alias (_, t2) -> unify' rec_env (t1, t2)
          | `Function (lfrom, lm, lto), `Function (rfrom, rm, rto) ->
              (unify' rec_env (lfrom, rfrom);
               unify_rows' rec_env (lm, rm);
               unify' rec_env (lto, rto))
          | `Record l, `Record r -> unify_rows' rec_env (l, r)
          | `Variant l, `Variant r -> unify_rows' rec_env (l, r)
          | `Table (lr, lw, ln), `Table (rr, rw, rn) ->
              (unify' rec_env (lr, rr);
               unify' rec_env (lw, rw);
               unify' rec_env (ln, rn))
          | `Application (l, _), `Application (r, _) when l <> r ->
              raise (Failure
                       (`Msg ("Cannot unify abstract type '"^string_of_datatype t1^
                                "' with abstract type '"^string_of_datatype t2^"'")))
          | `Application (l, ls), `Application (r, rs) ->
              List.iter2 (fun lt rt -> unify_type_args' rec_env (lt, rt)) ls rs
          | _, _ ->
              raise (Failure (`Msg ("Couldn't match "^ string_of_datatype t1 ^" against "^ string_of_datatype t2))));
       Debug.if_set (show_unification) (fun () -> "Unified types: " ^ string_of_datatype t1);
      )

and unify_presence' : unify_env -> ((presence_flag * presence_flag) -> unit) =
  fun rec_env (l, r) ->
    match l, r with
      | `Present, `Present
      | `Absent, `Absent -> ()
      | `Present, `Absent
      | `Absent, `Present ->
          raise (Failure (`Msg ("Present absent clash")))
(*`PresentAbsentClash (label, lrow, rrow) *)
      | `Var lpoint, `Var rpoint ->
          begin
            match Unionfind.find lpoint, Unionfind.find rpoint with
              | `Body l, _ -> unify_presence' rec_env (l, `Var rpoint)
              | _, `Body r -> unify_presence' rec_env (`Var lpoint, r)
              | `Rigid l, `Rigid r ->
                  if l <> r then 
                    raise (Failure (`Msg ("Rigid presence variables "^
                                            string_of_int l ^" and "^
                                            string_of_int r ^" do not match")))
                  else
                    Unionfind.union lpoint rpoint
              | `Flexible var, _ ->
                  Unionfind.union lpoint rpoint
              | _, `Flexible var ->
                  Unionfind.union rpoint lpoint
              | `Rigid l, _ ->
                  raise (Failure (`Msg ("Couldn't unify the rigid presence variable "^
                                          string_of_int l ^" with the presence variable "^
                                          string_of_presence (`Var rpoint))))
              | _, `Rigid r ->
                  raise (Failure (`Msg ("Couldn't unify the rigid presence variable "^
                                          string_of_int r ^" with the type "^
                                          string_of_presence (`Var lpoint))))
          end
      | `Var point, f | f, `Var point ->
          begin
            match (Unionfind.find point) with
              | `Rigid l -> 
                  raise (Failure (`Msg ("Couldn't unify the rigid presence variable "^
                                          string_of_int l ^" with the presence flag "^
                                          string_of_presence f)))
              | `Flexible var ->
                  Unionfind.change point (`Body f)
              | `Body f' -> unify_presence' rec_env (f, f')
          end
      | _, _ ->
          raise (Failure (`Msg ("Couldn't match "^ string_of_presence l ^" against "^ string_of_presence r)))

and unify_rows' : unify_env -> ((row * row) -> unit) = 
  fun ((_, _) as rec_env) (lrow, rrow) ->
    Debug.if_set (show_row_unification) (fun () -> "Unifying row: " ^ (string_of_row lrow) ^ " with row: " ^ (string_of_row rrow));

    (* 
       NOTE:

       - All calls to fail_on_absent_fields are currently disabled,
       as under the current model absent fields have
       to be allowed in closed rows (although they're ignored).

       - There's no way of getting rid of absent variables as they're stored in the field
       environment rather than the row variable (good argument for moving them into the
       row variable).
    *)
    (*
      let fail_on_absent_fields field_env =
      StringMap.iter
      (fun _ -> function
      | `Present _ -> ()
      | `Absent ->
      failwith "Internal error: closed row with absent variable"
      ) field_env in
    *)

    let is_unguarded_recursive row =
      let rec is_unguarded rec_rows (field_env, row_var) =
        StringMap.is_empty field_env &&
          (match Unionfind.find row_var with
             | `Closed
             | `Flexible _
             | `Rigid _ -> false
             | `Recursive (var, row) when IntSet.mem var rec_rows -> true
             | `Recursive (var, row) -> is_unguarded (IntSet.add var rec_rows) row
             | `Body row -> is_unguarded rec_rows row)
      in
        is_unguarded IntSet.empty row in

    (* extend_field_env traversal_env extending_env
       extends traversal_env with all the fields in extending_env

       Matching `Present fields are unified.

       Any fields in extending_env, but not in traversal_env are
       added to an extension environment which is returned.
    *)
    let extend_field_env
        (rec_env : unify_env)
        (traversal_env : field_spec_map)
        (extending_env : field_spec_map) =
      StringMap.fold
        (fun label field_spec extension ->
           if StringMap.mem label extending_env then
             let f, t = field_spec in
             let f', t' = StringMap.find label extending_env in
               unify_presence' rec_env (f, f');
               unify' rec_env (t, t');
               extension
           else
             StringMap.add label field_spec extension
        ) traversal_env (StringMap.empty) in

    let unify_compatible_field_environments rec_env (field_env1, field_env2) =
      ignore (extend_field_env rec_env field_env1 field_env2) in

    (* introduce a recursive row
       give an error if it is non-well-founded and
       non-well-founded type inference is switched off
    *)
    let rec_row_intro point (var, row) =
      if occurs_check_row var row then
        Unionfind.change point (`Recursive (var, row))
      else
        raise (Failure (`Msg ("Cannot unify row variable "^string_of_int var^" with row "^string_of_row row^
                                " because "^
                                match Settings.get_value infer_recursive_types with
                                  | "guarded" -> "the row variable occurs unguarded inside the row"
                                  | "positive" -> "the row variable occurs in a negative position inside the row"
                                  | _ -> assert false))) in

    (*
      unify_row_var_with_row rec_env (row_var, row)
      attempts to unify row_var with row
      
      However, row_var may already have been instantiated, in which case
      it is unified with row.
    *)
    let unify_row_var_with_row : unify_env -> row_var * row -> unit =
      fun rec_env (row_var, ((extension_field_env, extension_row_var) as extension_row)) ->
        (* unify row_var with `RowVar None *)
        let close_empty_row_var : row_var -> unit = fun point ->
          match Unionfind.find point with
            | `Closed -> ()
            | `Flexible _ ->
                Unionfind.change point `Closed
            | `Rigid _ ->
                raise (Failure (`Msg ("Closed row var cannot be unified with rigid row var\n")))
            | _ -> assert false in

        (* unify row_var with `RigidRowVar var *)
        let rigidify_empty_row_var (var, subkind) : row_var -> unit = fun point ->
          match Unionfind.find point with
            | `Closed ->
                raise (Failure (`Msg ("Rigid row var cannot be unified with empty closed row\n")))
            | `Flexible (_, subkind') ->
                if subkind = `Any && subkind' = `Base then
                  raise (Failure (`Msg ("Rigid non-base row var cannot be unified with empty base row\n")));
                Unionfind.change point (`Rigid (var, subkind))
            | `Rigid (var', _) when var=var' -> ()
            | `Rigid (var', _) ->
                raise (Failure (`Msg ("Incompatible rigid row variables cannot be unified\n")))
            | _ -> assert false in

        let rec extend = function
          | point ->
              (* point should be a row variable *)
              let row_var = Unionfind.find point in
                match row_var with
                  | `Closed ->
                      if is_empty_row extension_row then
                        close_empty_row_var extension_row_var
                      else
                        raise (Failure (`Msg ("Closed row cannot be extended with non-empty row\n"
                                              ^string_of_row extension_row)))
                  | `Rigid (var, subkind) ->
                      if is_empty_row extension_row then
                        rigidify_empty_row_var (var, subkind) extension_row_var
                      else
                        raise (Failure (`Msg ("Rigid row variable cannot be unified with non-empty row\n"
                                              ^string_of_row extension_row)))
                  | `Flexible (var, subkind) ->
                      if TypeVarSet.mem var (free_row_type_vars extension_row) then
                        begin
                          if subkind = `Base then
                            raise (Failure (`Msg ("Cannot infer a recursive type for the base row variable "^ string_of_int var ^
                                                    " with the body "^ string_of_row extension_row)));
                          rec_row_intro point (var, extension_row)
                        end
                      else
                        begin
                          if subkind = `Base then
                            if Types.is_baseable_row extension_row then
                              Types.basify_row extension_row
                            else
                              raise (Failure (`Msg ("Cannot unify the base row variable "^ string_of_int var ^
                                                      " with the non-base row "^ string_of_row extension_row)));
                          if StringMap.is_empty extension_field_env then
                            match extension_row_var with
                              | point' ->
                                  Unionfind.union point point'
                          else
                            Unionfind.change point (`Body extension_row)
                        end
                  | `Recursive _ ->
                      unify_rows' rec_env ((StringMap.empty, point), extension_row)
                  | `Body row ->
                      unify_rows' rec_env (row, extension_row)
        in
          extend row_var in

    (* 
       matching_labels (big_field_env, small_field_env)
       return the set of labels that appear in both big_field_env and small_field_env

       precondition: big_field_env contains small_field_env
    *)
    let matching_labels : field_spec_map * field_spec_map -> StringSet.t = 
      fun (big_field_env, small_field_env) ->
        StringMap.fold (fun label _ labels ->
                          if StringMap.mem label small_field_env then
                            StringSet.add label labels
                          else
                            labels) big_field_env StringSet.empty in

    let row_without_labels : StringSet.t -> row -> row =
      fun labels (field_env, row_var) ->
        let restricted_field_env =
          StringSet.fold (fun label field_env ->
                            StringMap.remove label field_env) labels field_env
        in
          (restricted_field_env, row_var) in

    (*
      register a recursive row in the rec_env environment
      
      return:
      None if the recursive row already appears in the environment
      Some rec_env, otherwise, where rec_env is the updated environment
    *)
    let register_rec_row (wrapped_field_env, unwrapped_field_env, rec_row, unwrapped_row') : unify_env -> unify_env option =
      fun ((rec_types, rec_rows) as rec_env) ->
        match rec_row with
          | Some row_var ->
              begin
                match Unionfind.find row_var with
                  | `Recursive (var, _) ->
                      let restricted_row = row_without_labels (matching_labels (unwrapped_field_env, wrapped_field_env)) unwrapped_row' in
                      let rs =
                        if IntMap.mem var rec_rows then
                          IntMap.find var rec_rows
                        else
                          [(StringMap.empty, row_var)]
                      in
                        if List.exists (fun r ->
                                          eq_rows (r, restricted_row)) rs then
                          None
                        else
                          Some (rec_types, IntMap.add var (restricted_row::rs) rec_rows)
                  | _ -> assert false
              end
          | None ->
              Some rec_env in

    (*
      register two recursive rows and return None if one of them is already in the environment
    *)
    let register_rec_rows p1 p2 : unify_env -> unify_env option = fun rec_env ->
      let rec_env' = register_rec_row p1 rec_env in
        match rec_env' with
          | None -> None
          | Some rec_env -> register_rec_row p2 rec_env in

    let unify_both_rigid_with_rec_env rec_env ((lfield_env, _ as lrow), (rfield_env, _ as rrow)) =
      (* return the present labels from an unwrapped row *)
      let get_present_labels (field_env, _row_var) =
        StringMap.fold
          (fun label (flag, _) labels ->
             match flag with
               | `Present -> StringSet.add label labels
               | `Absent
               | `Var _ -> labels)
          field_env
          StringSet.empty in

      (* return the present / flexible labels from an unwrapped row *)
      let get_possibly_present_labels (field_env, _row_var) =
        StringMap.fold
          (fun label (flag, _) labels ->
             match flag with
               | `Present -> StringSet.add label labels
               | `Absent -> labels
               | `Var point ->
                   begin
                     match Unionfind.find point with
                       | `Flexible _ -> StringSet.add label labels
                       | `Rigid _ -> labels
                       | `Body _ -> assert false
                   end)
          field_env
          StringSet.empty in

      (* check that the field labels can possibly match up *)
      let fields_are_compatible (lrow, rrow) =
        (StringSet.subset (get_present_labels lrow) (get_possibly_present_labels rrow)) &&
        (StringSet.subset (get_present_labels rrow) (get_possibly_present_labels lrow)) in

      let (lfield_env', lrow_var') as lrow', lrec_row = unwrap_row lrow in
      let (rfield_env', rrow_var') as rrow', rrec_row = unwrap_row rrow in
        (*
          fail_on_absent_fields lfield_env;
          fail_on_absent_fields rfield_env;
        *)
        match Unionfind.find lrow_var', Unionfind.find rrow_var' with
          | `Rigid lvar, `Rigid rvar when lvar <> rvar ->
              raise (Failure (`Msg ("Rigid rows\n "^ string_of_row lrow
                                    ^"\nand\n "^ string_of_row lrow
                                    ^"\n could not be unified because they have distinct rigid row variables")))
          | _, _ ->
              if fields_are_compatible (lrow', rrow') then
                let rec_env' =
                  (register_rec_rows
                     (lfield_env, lfield_env', lrec_row, rrow')
                     (rfield_env, rfield_env', rrec_row, lrow')
                     rec_env)
                in
                  match rec_env' with
                    | None -> ()
                    | Some rec_env ->
                        unify_compatible_field_environments rec_env (lfield_env', rfield_env')
              else
                raise (Failure (`Msg ("Rigid rows\n "^ string_of_row lrow
                                      ^"\nand\n "^ string_of_row rrow
                                      ^"\n could not be unified because they have different fields"))) in

    let unify_both_rigid = unify_both_rigid_with_rec_env rec_env in

    let unify_one_rigid ((rigid_field_env, _ as rigid_row), (open_field_env, _ as open_row)) =
      let (rigid_field_env', rigid_row_var') as rigid_row', rigid_rec_row = unwrap_row rigid_row in
      let (open_field_env', open_row_var') as open_row', open_rec_row = unwrap_row open_row in 
        (* check that the open row contains no extra fields *)
        StringMap.iter
          (fun label (flag, _) ->
             if (StringMap.mem label rigid_field_env') then
               ()
             else
               match flag with
                 | `Present ->
                     raise (Failure
                              (`Msg 
                                 ("Rows\n "^ string_of_row rigid_row
                                  ^"\nand\n "^ string_of_row open_row
                                  ^"\n could not be unified because the former is rigid"
                                  ^" and the latter contains fields not present in the former")))
                 | `Absent -> ()
                 | `Var _ -> () (* TODO *)
          ) open_field_env';
        
        (* check that the closed row contains no absent fields *)
        (*          fail_on_absent_fields closed_field_env; *)
        
        let rec_env' =
          (register_rec_rows
             (rigid_field_env, rigid_field_env', rigid_rec_row, open_row')
             (open_field_env, open_field_env', open_rec_row, rigid_row')
             rec_env)
        in
          match rec_env' with
            | None -> ()
            | Some rec_env ->
                let open_extension = extend_field_env rec_env rigid_field_env' open_field_env' in
                  unify_row_var_with_row rec_env (open_row_var', (open_extension, rigid_row_var')) in

    let unify_both_open ((lfield_env, _ as lrow), (rfield_env, _ as rrow)) =
      let (lfield_env', lrow_var') as lrow', lrec_row = unwrap_row lrow in
      let (rfield_env', rrow_var') as rrow', rrec_row = unwrap_row rrow in
      let rec_env' =
        (register_rec_rows
           (lfield_env, lfield_env', lrec_row, rrow')
           (rfield_env, rfield_env', rrec_row, lrow')
           rec_env)
      in
        match rec_env' with
          | None -> ()
          | Some rec_env ->
              if (get_row_var lrow = get_row_var rrow) then     
                unify_both_rigid_with_rec_env rec_env ((lfield_env', Unionfind.fresh `Closed),
                                                       (rfield_env', Unionfind.fresh `Closed))
              else
                begin
                  let fresh_row_var = fresh_row_variable `Any in         
                    (* each row can contain fields missing from the other; 
                       thus we call extend_field_env once in each direction *)
                  let rextension =
                    extend_field_env rec_env lfield_env' rfield_env' in
                    (* NOTE:
                       extend_field_env may change rrow_var' or lrow_var', as either
                       could occur inside the body of lfield_env' or rfield_env'
                    *)
                    unify_row_var_with_row rec_env (rrow_var', (rextension, fresh_row_var));
                    let lextension = extend_field_env rec_env rfield_env' lfield_env' in
                      unify_row_var_with_row rec_env (lrow_var', (lextension, fresh_row_var))
                end in
      
    (* report an error if an attempt is made to unify
       an unguarded recursive row with a row that is not
       unguarded recursive
    *)
    let check_unguarded_recursion lrow rrow =      
      if is_unguarded_recursive lrow then
        if not (is_unguarded_recursive rrow) then
          raise (Failure
                   (`Msg ("Could not unify unguarded recursive row"^ string_of_row lrow
                          ^"\nwith row "^ string_of_row rrow)))
        else if is_unguarded_recursive rrow then
          raise (Failure
                   (`Msg ("Could not unify unguarded recursive row"^ string_of_row rrow
                          ^"\nwith row "^ string_of_row lrow))) in
      
    let _ =
      check_unguarded_recursion lrow rrow;

      if is_rigid_row lrow then
        if is_rigid_row rrow then
          unify_both_rigid (lrow, rrow)
        else
          unify_one_rigid (lrow, rrow)
      else if is_rigid_row rrow then
        unify_one_rigid (rrow, lrow)        
      else
        unify_both_open (rrow, lrow)
    in
      Debug.if_set (show_row_unification)
        (fun () -> "Unified rows: " ^ (string_of_row lrow) ^ " and: " ^ (string_of_row rrow))

and unify_type_args' : unify_env -> (type_arg * type_arg) -> unit =
  fun rec_env ->
    function
      | `Type lt, `Type rt -> unify' rec_env (lt, rt)
      | `Row lr, `Row rr -> unify_rows' rec_env (lr, rr)
      | `Presence lf, `Presence rf -> unify_presence' rec_env (lf, rf)
      | l, r -> 
          raise (Failure (`Msg ("Couldn't match "^ string_of_type_arg l ^" against "^ string_of_type_arg r)))

let unify (t1, t2) =
  unify' (IntMap.empty, IntMap.empty) (t1, t2)
(* Debug.if_set (show_unification) (fun () -> "Unified types: " ^ string_of_datatype t1) *)
and unify_rows (row1, row2) =
  unify_rows' (IntMap.empty, IntMap.empty) (row1, row2)

(* external interface *)
let datatypes = unify
let rows = unify_rows

