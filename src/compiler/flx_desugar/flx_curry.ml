
open Flx_version
open Flx_util
open Flx_list
open Flx_ast
open Flx_types
open Flx_set
open Flx_mtypes2
open Flx_print
open Flx_typing
open Flx_typing2
open Flx_pat
open Flx_exceptions
let generated = Flx_srcref.make_dummy "[flx_desugar_expr] generated"


(** A helper function to take two opt[expressions] in, boolean conjunct them,
    and wrap back into an opt. *)
let inv_join l r sr = 
  match l, r with
  | None, None -> None
  | None, Some i2 -> r
  | Some i1, None -> l
  | Some i1, Some i2 -> 
      Some( EXPR_apply (sr, 
        (EXPR_name (sr, "land", []), 
         EXPR_tuple (sr, [i1; i2]))))

(** Scoop up invariants from the body of a function and return them as an expression *)
let invariants_of_stmts body sr =
  let invariants = ref [] in

  List.iter 
    (fun st ->
      match st with
      | STMT_invariant (_, e)  as invariant -> 
          invariants := invariant :: !invariants
      | _ -> ()
    )
    body;
  
  (* take the statements, pull out expression and then boolean and them (e and (e2 and ...)) *)
  let conjunction =
    match !invariants with
    | [] -> None
    | _ -> 
      Some(
        List.fold_left 
          (fun x y -> 
            match y with
            | STMT_invariant (sr, e) ->
               EXPR_apply (sr, (EXPR_name (sr, "land", []), EXPR_tuple (sr, [x; e]))) 
            | _ -> failwith "Unexpected statement type found processing invariants"
          ) 
          (EXPR_typed_case (sr, 1, TYP_unitsum 2)) 
          !invariants
      )
    in
    conjunction


(* Removes everything except invariants, becuase those aren't allowed to be run. *)
let propagate_invariants body invariants sr =

  let addpost p i = 
      begin match p,i with
      | None,None -> None
      | None,Some _ -> i
      | Some _, None -> p
      | Some post, Some inv -> Some( EXPR_apply (sr, (EXPR_name (sr, "land", []), EXPR_tuple (sr, [post; inv]))))
      end
  in

  let newstatements = ref [] in

  List.iter (fun st ->
    match st with
    (* Erase invariants from the original expression. *)
    | STMT_invariant (_, _) -> ()

    (* propagate invariants to deeper levels (i.e. object -> method) *)
    | STMT_curry (sr, name, vs, pss, (res,traint) , effects, kind, adjectives, ss)
            when kind = `Method || kind = `GeneratorMethod -> 

        let inv2 = addpost traint invariants in 
        newstatements := 
          STMT_curry (sr,name, vs, pss, (res,inv2) , effects, kind, adjectives, ss)
          :: !newstatements

    (* Just accumulate everything else. *)
    | _ -> 
        newstatements := st :: !newstatements
  )
  body;

  (* Becuase the statements get added backwards, reverse to correct it. *)
  let body = List.rev !newstatements in 
  body



(** Iterate over parameters and create type variables when needed. *)
let fix_params sr seq ps =

  let rec aux ps =
    (* ps : (param_kind_t * Flx_id.t * typecode_t * expr_t option) *)
    match ps with

    (* The case where the param type is none. 
       This is where things like 'could not match type "_v4029" with "int" in "x + 3"' originate *)
    | (kind,id,TYP_none,expr) :: t ->

      let v = "_v" ^ string_of_bid (seq()) in  (* Create a fresh identifier *)
      let vt = TYP_name (generated,v,[]) in    (* Create a new type variable w/ dummy source ref. *)
      let vs,ps = aux t in                     (* work on the other cases before wrapping up. *)

      (* Add our new type in to the sequence. It has the new type of TYP_patany
         which should trigger future processing for type binding. *)
      ((v,TYP_patany sr)::vs),((kind,id,vt,expr)::ps) (* a bit HACKY *)

    (* General case: Recurse assmbling the fixed type variables (vs). *)
    | h :: t ->
      let vs,ps = aux t in
      vs, (h::ps)

    (* Empty case: no input, no output. *)
    | [] -> [],[]
  in

  let ps, traint = ps in   (* Split ps into type variables and type constraints *)
  let vs,ps = aux ps in    (* Process params *)
  vs,(ps,traint)           (* Reassemble *)


let cal_props kind props = match kind with
  | `CFunction -> `Cfun::props
  | `InlineFunction -> if not (List.mem `Inline props) then `Inline::props else props
  | `GeneratedInlineProcedure-> `GeneratedInline::props
  | `GeneratedInlineFunction -> `GeneratedInline::props
  | `NoInlineFunction -> if not (List.mem `NoInline props) then `NoInline::props else props
  | `Ctor -> `Ctor::props
  | `Generator -> (* `NoInline:: *) `Generator::props
  | `GeneratorMethod -> (* `NoInline:: *) `Generator::props
  | `Virtual -> if not (List.mem `Virtual props) then `Virtual::props else props
  | _ -> []

(** Currying, A.K.A. Shonfinkeling *)
let mkcurry seq sr name vs args return_type effects kind body props =

  (* preflight checks *)
  if List.mem `Lvalue props then
    clierrx "[flx_desugar/flx_curry.ml:152: E318] " sr "Felix function cannot return lvalue";
  if List.mem `Pure props && match return_type with  | TYP_void _,_ -> true | _ -> false then
    clierrx "[flx_desugar/flx_curry.ml:154: E319] " sr "Felix procedure cannot be pure";

  (* Manipulate the type variables ----- *)

  (* vs = type variables and tcon = type constraints *)
  let vs, tcon = vs in

  (* Iterate over parameters and determine if new type variables need to be created *)
  (* New ones are stored in vss' *)
  let vss',args = 
    List.split 
      (List.map (fix_params sr seq) args) in 

  (* Reassemble vs back together *)
  let vs = List.concat (vs :: vss') in
  let vs : vs_list_t = vs,tcon in

  let return_type, postcondition = return_type in

  let typeoflist lst = match lst with
    | [x] -> x
    | _ -> TYP_tuple lst
  in

  let mkret arg (eff,ret) = 
    Flx_typing.flx_unit,
    TYP_effector 
      ((typeoflist 
        (List.map 
          (fun(x,y,z,d)->z) 
          (fst arg))),
      eff,
      ret)
  in

  let arity = List.length args in

  let rettype args eff =
    match return_type with
    | TYP_none -> TYP_none
    | _ -> 
        snd 
          (List.fold_right 
            mkret 
            args 
            (eff,return_type))
  in

  let isobject = kind = `Object in
  let rec aux (args:params_t list) (vs:vs_list_t) props =

    (* Gather invariants from: param constraints and from invariant statements *)
    let _,traints = List.split args in
    let pre_inv = match traints with | Some(h) :: t -> Some(h) | _ -> None in
    let post_inv = invariants_of_stmts body sr in 
    let invariants = inv_join pre_inv post_inv sr in

    (* propagate invariants into child functions *)
    let body = propagate_invariants body invariants sr in

    (* merge invariants with the current closure's post conditions *)
    let postcondition = inv_join postcondition invariants sr in

    let n = List.length args in
    let synthname n =
      if n = arity
      then name
      else name^"'" ^ si (arity-n+1)
    in
    match args with
    | [] ->
        begin match return_type with
        | TYP_void _ ->
          let body = 
            let reved = List.rev body in
            List.rev (STMT_label (sr,"_endof_" ^ synthname n) ::
              match reved with
              | STMT_proc_return _ :: _ ->  reved
              | _ -> STMT_proc_return sr :: reved
            )
          in
          STMT_function (sr, synthname n, vs, ([],None), (return_type,postcondition), effects, props, body)

        | _ ->
          (* allow functions with no arguments now .. *)
          begin match body with
          | [STMT_fun_return (_,e)] ->
            let rt = match return_type with
            | TYP_none -> None
            | x -> Some x
            in
            STMT_lazy_decl (sr, synthname n, vs, rt, Some e)
          | _ ->
            clierrx "[flx_desugar/flx_curry.ml:247: E320] " sr "Function with no arguments"
          end
        end

    | h :: [] -> (* bottom level *)
      if isobject then begin
        (*
        print_endline "Found an object, scanning for methods and bogus returns";
        *)
        let methods = ref [] in

        List.iter 
          (fun st ->
            (*
            print_endline ("Statement " ^ Flx_print.string_of_statement 2 st);
            *)
            match st with
            | STMT_fun_return _ -> clierrx "[flx_desugar/flx_curry.ml:264: E321] " sr "FOUND function RETURN in Object";
            | STMT_proc_return _ -> clierrx "[flx_desugar/flx_curry.ml:265: E322] " sr "FOUND procedure RETURN in Object";
            | STMT_curry (_,name, vs, pss, (res,traint) , effects, kind, adjectives, ss)
                when kind = `Method || kind = `GeneratorMethod -> 
                methods := name :: !methods
            | _ -> ()
          )
          body
        ;

        (* Calculate methods to attach to return type *)
        let revbody = List.rev body in 
        let mkfield s = s,EXPR_name (sr,s,[]) in
        let record = EXPR_record (sr, List.map mkfield (!methods)) in
        let retstatement = STMT_fun_return (sr, record) in
        let revbody = retstatement :: revbody in
        let body = List.rev revbody in

        (* print_endline ("Object " ^name^ " return type " ^ string_of_typecode return_type); *)
        STMT_function (sr, synthname n, vs, h, (return_type, postcondition), effects,props, body)

      end else 
        let body = 
          match return_type with
          | TYP_void _  ->
(*
            print_endline ("(args) Name = " ^ name ^ "synthname n = " ^ synthname n);
*)
            let reved = List.rev body in
            List.rev (STMT_label (sr,"_endof_" ^ synthname n) ::
              match reved with
              | STMT_proc_return _ :: _ ->  reved
              | _ -> STMT_proc_return sr :: reved
            )
          | _ -> body
        in
        STMT_function (sr, synthname n, vs, h, (return_type,postcondition), effects,props, body)

    | h :: t ->
      let argt =
        let hdt = List.hd t in
        let xargs,traint = hdt in
        typeoflist (List.map (fun (x,y,z,d) -> z) xargs)
      in
      let m = List.length args in
      let body = [ 
        aux t dfltvs []; 
        STMT_fun_return ( sr, EXPR_suffix ( sr, ( `AST_name (sr,synthname (m-1),[]),argt))) ] 
      in
      let noeffects = Flx_typing.flx_unit in
      STMT_function (sr, synthname m, vs, h, (rettype t effects,postcondition), noeffects,`Generated "curry"::props, body)

   in aux args vs (cal_props kind props)



