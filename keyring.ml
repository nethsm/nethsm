open Lwt.Infix

module YB = Yojson.Basic

module Priv = struct
  type data =
    | Rsa of Nocrypto.Rsa.priv
  type t = {
    purpose: string;
    data: data;
  }
end

type priv = Priv.t

module Pub = struct
  type data =
    | Rsa of Nocrypto.Rsa.pub
  type t = {
    purpose: string;
    data: data;
  }
end

type pub = Pub.t

type storage = (int * Priv.t) list Lwt_mvar.t


(* Simple database to store the items *)
module Db = struct
  let create () =
    Lwt_mvar.create []

  let id = ref 0

  let with_db db ~f =
    Lwt_mvar.take db   >>= fun l ->
      let result, l' = f l in
      Lwt_mvar.put db l' >|= fun () ->
        result

  let get db id =
    with_db db ~f:(fun l ->
      if (List.mem_assoc id l) then
        (Some(id, List.assoc id l), l)
      else
        (None, l))

  let get_all db =
    with_db db ~f:(fun l -> (l, l))

  let add db e =
    with_db db ~f:(fun l ->
      incr id;
      let l' = List.merge (fun x y -> compare (fst x) (fst y)) [!id, e] l in
      (!id, l'))

  let put db id e =
    let found = ref false in
    with_db db ~f:(fun l ->
      let l' = List.map (fun (id', e') ->
        if id' = id
          then begin found := true; (id', e) end
          else (id', e'))
        l
      in
      (!found, l'))

  let delete db id =
    let deleted = ref false in
    with_db db ~f:(fun l ->
      let l' = List.filter (fun (id', _) ->
        if id' = id
          then begin deleted := true; false end
          else true)
        l
      in
      (!deleted, l'))
end

(* helper functions *)

let pub_of_priv { Priv.purpose; data } =
  let data = match data with
    | Priv.Rsa d -> Pub.Rsa (Nocrypto.Rsa.pub_of_priv d)
  in
  { Pub.purpose; data }

let trim_tail s =
  let rec f n = if n>=0 && s.[n]='\000' then f (pred n) else n in
  let len = String.length s |> pred |> f |> succ in
  String.sub s 0 len

let b64_of_z z =
  Nocrypto.Numeric.Z.to_cstruct_be z |> Cstruct.to_string
    |> B64.encode ~alphabet:B64.uri_safe_alphabet

let z_of_b64 s =
  B64.decode ~alphabet:B64.uri_safe_alphabet s |> Cstruct.of_string
    |> Nocrypto.Numeric.Z.of_cstruct_be

let pq_of_ned n e d =
  let open Z in
  let de = e*d in
  let modplus1 = n + one in
  let deminus1 = de - one in
  let kprima = de/n in
  let ks = [kprima; kprima + one; kprima - one] in
  let rec f = function
    | [] -> assert false
    | k :: rest -> let fi = deminus1 / k in
      let pplusq = modplus1 - fi in
      let delta = pplusq*pplusq - n*(of_int 4) in
      let sqr = sqrt delta in
      let p = (pplusq + sqr)/(of_int 2) in
      if (n mod p) = Z.zero && p > zero
        then let q = (pplusq - sqr)/(of_int 2) in
          (p, q)
        else f rest
  in
  f ks


(* public functions *)

let pem_of_pub { Pub.data } =
  let Pub.Rsa k = data in
  `RSA k |> X509.Encoding.Pem.Public_key.to_pem_cstruct1 |> Cstruct.to_string

let priv_of_pem s =
  Cstruct.of_string s |> X509.Encoding.Pem.Private_key.of_pem_cstruct1
    |> function `RSA key -> key

let json_of_pub { Pub.purpose; data } =
  let json_hd = [
    ("purpose", `String purpose);
    ]
  in
  let json_data = match data with
    | Pub.Rsa { Nocrypto.Rsa.e; n} -> [
      ("algorithm", `String "RSA");
      ("publicKey", `Assoc [
        ("modulus", `String (b64_of_z n));
        ("publicExponent", `String (b64_of_z e));
        ])
      ]
  in
  `Assoc (json_hd @ json_data)

let priv_of_json = function
  | `Assoc obj ->
    let purpose = YB.Util.to_string @@ List.assoc "purpose" obj in
    (* let algorithm =
      YB.Util.to_string @@ List.Assoc.find_exn obj "algorithm" in *)
    let data =
      try
        let priv = YB.Util.to_assoc @@ List.assoc "privateKey" obj in
        let e = z_of_b64 @@ YB.Util.to_string @@ List.assoc "publicExponent" priv in
        let p = z_of_b64 @@ YB.Util.to_string @@ List.assoc "primeP" priv in
        let q = z_of_b64 @@ YB.Util.to_string @@ List.assoc "primeQ" priv in
        Priv.Rsa (Nocrypto.Rsa.priv_of_primes e p q)
      with
        | Not_found -> Priv.Rsa (Nocrypto.Rsa.generate 2048)
    in
    { Priv.purpose; data }
  | _ -> assert false

let create () = Db.create ()

let add ks k = Db.add ks k

let put ks id k = Db.put ks id k

let del ks id = Db.delete ks id

let get ks id = Db.get ks id >|= function
  | None -> None
  | Some (_, k) -> Some (pub_of_priv k)

let get_all ks = Db.get_all ks >|= List.map (fun (id, key) ->
    (id, pub_of_priv key))
