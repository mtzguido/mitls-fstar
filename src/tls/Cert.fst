﻿(* Copyright (C) 2012--2015 Microsoft Research and INRIA *)
module Cert

open Platform.Bytes
open Platform.Error
open TLSError
open TLSConstants
open CoreCrypto
open Signature

type hint = string
type cert = b:bytes {length b <= 16777215}
type chain = list cert

abstract val certificateListBytes: chain -> Tot bytes
let rec certificateListBytes l =
  match l with
  | [] -> empty_bytes
  | c::r -> 
    lemma_repr_bytes_values (length c);
    (vlbytes 3 c) @| (certificateListBytes r)

val certificateListBytes_is_injective: c1:chain -> c2:chain ->
  Lemma (requires (True))
	(ensures (Seq.equal (certificateListBytes c1) (certificateListBytes c2) ==> c1 = c2))
let rec certificateListBytes_is_injective c1 c2 =
  match c1, c2 with
  | [], [] -> ()
  | hd::tl, hd'::tl' ->
      if certificateListBytes c1 = certificateListBytes c2 then (
	lemma_repr_bytes_values (length hd); lemma_repr_bytes_values (length hd');
	cut(Seq.equal ((vlbytes 3 hd) @| (certificateListBytes tl)) ((vlbytes 3 hd') @| (certificateListBytes tl')));
	lemma_repr_bytes_values (length hd);
	lemma_repr_bytes_values (length hd');	
	cut(Seq.equal (Seq.slice (vlbytes 3 hd) 0 3) (Seq.slice (certificateListBytes c1) 0 3));
	cut(Seq.equal (Seq.slice (vlbytes 3 hd') 0 3) (Seq.slice (certificateListBytes c1) 0 3));
	vlbytes_length_lemma 3 hd hd';
	lemma_append_inj (vlbytes 3 hd) (certificateListBytes tl) (vlbytes 3 hd') (certificateListBytes tl');
	lemma_vlbytes_inj 3 hd hd';
	certificateListBytes_is_injective tl tl';
	()
      )
  | [], hd::tl -> (
      cut (length (certificateListBytes c1) = 0); 
      lemma_repr_bytes_values (length hd);
      cut (Seq.equal (certificateListBytes c2) ((vlbytes 3 hd) @| (certificateListBytes tl)));
      lemma_vlbytes_len 3 hd
    )
  | hd::tl, [] -> (
      cut (length (certificateListBytes c2) = 0); 
      lemma_repr_bytes_values (length hd);
      cut (Seq.equal (certificateListBytes c1) ((vlbytes 3 hd) @| (certificateListBytes tl)));
      lemma_vlbytes_len 3 hd
  )
	
abstract val parseCertificateList: b:bytes -> Tot (result chain) (decreases (length b))
let rec parseCertificateList b =
  if length b >= 3 then
    match vlsplit 3 b with
    | Correct (c,r) ->
	cut (repr_bytes (length c) <= 3);
        let rl = parseCertificateList r in
        (match rl with
        | Correct x -> (
	    lemma_repr_bytes_values (length c);
	    Correct (c::x)
	    )
        | e -> e)
    | _ -> Error(AD_bad_certificate_fatal, perror __SOURCE_FILE__ __LINE__ "Badly encoded certificate list")
  else if length b = 0 then Correct []
  else Error(AD_bad_certificate_fatal, perror __SOURCE_FILE__ __LINE__ "Badly encoded certificate list")

val lemma_parseCertificateList_length: b:bytes -> 
  Lemma (requires (True))
	(ensures (match parseCertificateList b with
		  | Correct ces -> length (certificateListBytes ces) = length b
		  | _ -> True))
	(decreases (length b))
let rec lemma_parseCertificateList_length b = 
  match parseCertificateList b with
  | Correct([]) -> ()
  | Correct (hd::tl) -> begin
      cut(length b >= 3);
      match vlsplit 3 b with
      | Correct (c, r) ->
	  lemma_parseCertificateList_length r;
	  ()
      | _ -> ()
    end
  | Error _ -> ()

(* JK: why is that necessary ? *)
let rec list_chain_is_list_bytes (c:chain) : Tot (list bytes) = 
  match c with
  | [] -> []
  | hd::tl -> hd::(list_chain_is_list_bytes tl)

val validate_chain : chain -> option sigAlg -> option string -> string -> Tot bool
let validate_chain c sigalg host cafile =
  let for_signing = match sigalg with | None -> false | _ -> true in
  let c = list_chain_is_list_bytes c in
  CoreCrypto.validate_chain c for_signing host cafile

val get_chain_public_signing_key : chain -> sigAlg -> Tot (result Signature.public_repr)
let get_chain_public_signing_key c a =
  match c with
  | cert::_ -> (
    (* let cert = List.Tot.hd c in *)
    match a with
    | DSA ->
      begin
      match CoreCrypto.get_dsa_from_cert cert with
      | None -> Error(AD_internal_error, perror __SOURCE_FILE__ __LINE__ "failed to get signing key")
      | Some k -> Correct (PK_DSA k)
      end
      | RSASIG ->
      begin
      match CoreCrypto.get_rsa_from_cert cert with
      | None -> Error(AD_internal_error, perror __SOURCE_FILE__ __LINE__ "failed to get signing key")
      | Some k -> Correct (PK_RSA k)
      end
      | ECDSA ->
      begin
      match CoreCrypto.get_ecdsa_from_cert cert with
      | None -> Error(AD_internal_error, perror __SOURCE_FILE__ __LINE__ "failed to get signing key")
      | Some k -> Correct (PK_ECDSA k)
      end
      | RSAPSS ->
    Error(AD_internal_error, perror __SOURCE_FILE__ __LINE__ "unimplemented") )
  | _ -> Error(AD_internal_error, perror __SOURCE_FILE__ __LINE__ "unimplemented") 

let optHashAlg_prime_is_optHashAlg (ha:result hashAlg') : Tot (result hashAlg) =
  match ha with
  | Error(z) -> Error(z)
  | Correct(h) -> Correct(h)

let sigHashAlg_is_tuple_sig_hash (sha:sigHashAlg) : Tot (sigAlg * hashAlg) = 
  match sha with | a,b -> a,b

let rec list_sigHashAlg_is_list_tuple_sig_hash (lsha:list sigHashAlg) : Tot (list (sigAlg * hashAlg)) =
  match lsha with
  | [] -> []
  | hd::tl -> (sigHashAlg_is_tuple_sig_hash hd)::(list_sigHashAlg_is_list_tuple_sig_hash tl)

(* TODO: FIXME, an assumed hypothesis in the body *)
val verify_signature : chain -> pv:protocolVersion -> role -> csr:option bytes{is_None csr <==> pv = TLS_1p3} -> sigAlg -> option (list sigHashAlg) -> tbs:bytes -> sigv:bytes -> ST bool (fun _ -> True) (fun _ _ _ -> True)
let verify_signature c pv role nonces csa sigalgs tbs sigv =
  if length sigv > 4 then
   let (h, r) = split sigv 1 in
   let (sa, sigv) = split r 1 in
   begin
   match vlsplit 2 sigv with
   | Correct (sigv, eof) ->
       let tbs =
	 begin
         match pv with
         | TLS_1p3 ->
           let pad = abytes (String.make 64 (Char.char_of_int 32)) in
           let ctx = match role with
             | Server -> "TLS 1.3, server CertificateVerify"
             | Client -> "TLS 1.3, client CertificateVerify" in
           pad @| (abytes ctx) @| (abyte 0z) @| tbs
         | _ -> (Some.v nonces) @| tbs
	 end
       in
       begin
	 match (length eof, parseSigAlg sa, optHashAlg_prime_is_optHashAlg(parseHashAlg h)) with
         | 0, Correct sa, Correct (Hash h) ->
           let algs : list sigHashAlg =
	     begin
	     match sigalgs with
             | Some l -> l
             | None -> [(csa, Hash CoreCrypto.SHA1)]
	     end in
             if List.Tot.existsb (fun (xs,xh)->(xs=sa && xh=Hash h)) (list_sigHashAlg_is_list_tuple_sig_hash algs) then
	       begin
	       match get_chain_public_signing_key c sa with
	       | Correct pk ->
	         let a = Signature.Use (fun _ -> True) sa [Hash h] false false in
	         let (|a,pk|) = endorse #a pk in
		 let h' = Hash h in
		 assume (List.Tot.mem h' a.digest);
                 Signature.verify #a h' pk tbs sigv
	       | Error z -> false
	       end
             else false
         | _ -> false
	 end
    | _ -> false
    end
  else false

(* JK: TODO: Not tailrec *)
let rec check_length (l:list bytes) : Tot (result chain) =
  match l with
  | [] -> Correct []
  | hd::tl ->
    match check_length tl with
    | Correct l' ->
      if length hd < 16777216 then Correct (hd :: l')
      else Error(AD_decode_error, perror __SOURCE_FILE__ __LINE__ "")
    | _ -> Error(AD_decode_error, perror __SOURCE_FILE__ __LINE__ "")

val lookup_server_chain: string -> string -> protocolVersion -> option sigAlg -> option (list sigHashAlg) -> Tot (result (chain * CoreCrypto.certkey))
let lookup_server_chain pem key pv sa ext_sig =
(** TODO
  let sal =
    if is_None sa then None
    else
      let sa = Some.v sa in
      (match ext_sig with
      | None ->
        (match pv with
        | TLS_1p3 -> Error(AD_missing_extension, perror __SOURCE_FILE__ __LINE__ "missing supported signature algorithm extension in a 1.3 signature-based ciphersuite") // 6.3.2.1 of TLS 1.3 requires sending the "missing extension" alert 
        | _ -> Correct (Some (sa, Hash CoreCrypto.SHA1)))
               // This doesn't comply with 7.4.1.4.1. of RFC5246
               // which requires selecting RSASIG regardless of the CS's sigAlg
               // (thus enabling the use of ECDHE_ECDSA with RSA cert if extension is omitted)
      | Some al -> List.Tot.tryFind (fun (s,_)->s=sa) al) in
*)
  match CoreCrypto.cert_load_chain pem key with
  | Some (csk, chain) -> (
      match check_length chain with
      | Correct chain -> Correct (chain, csk)
      | Error z -> Error z)
  | None -> Error(AD_no_certificate, perror __SOURCE_FILE__ __LINE__ "cannot find suitable server certificate")

val sign: pv:protocolVersion -> role -> csr:option bytes{is_None csr <==> pv = TLS_1p3} -> CoreCrypto.certkey -> sigHashAlg -> bytes -> Tot (result bytes)
let sign pv role csr csk sha tbs =
  let (sa, ha) = sha in
  let Hash h = ha in
  let hab, sab = hashAlgBytes ha, sigAlgBytes sa in
  let tbs = match pv with
    | TLS_1p3 ->
      let pad = abytes (String.make 64 (Char.char_of_int 32)) in
      let ctx = (match role with
        | Server -> "TLS 1.3, server CertificateVerify"
        | Client -> "TLS 1.3, client CertificateVerify") in
      pad @| (abytes ctx) @| (abyte 0z) @| tbs
    | _ -> (Some.v csr) @| tbs in
  match CoreCrypto.cert_sign csk sa h tbs with
  | Some sigv -> (
      if length sigv >= 2 && length sigv < 65536 then (
	lemma_repr_bytes_values (length sigv);
	Correct (hab @| sab @| (vlbytes 2 sigv))
	)
      else Error(AD_decode_error, perror __SOURCE_FILE__ __LINE__ "")
      )
  | None -> Error(AD_internal_error, perror __SOURCE_FILE__ __LINE__ "failed to sign")

//let certificate_sign: chain -> 

(*
type sign_cert = option (chain * Sig.alg * Sig.skey)
type enc_cert  = option (chain * RSAKey.sk)

abstract val for_signing : list Sig.alg -> hint -> list Sig.alg -> sign_cert
let for_signing l h l2 = failwith "Not implemented"

abstract val for_key_encryption : list Sig.alg -> hint -> enc_cert
let for_key_encryption l h = failwith "Not implemented"

abstract val get_public_signing_key : cert -> Sig.alg -> result Sig.pkey
let get_public_signing_key c a = failwith "Not implemented"

abstract val get_public_encryption_key : cert -> result RSAKey.pk
let get_public_encryption_key c = failwith "Not implemented"

abstract val get_chain_public_signing_key : chain -> Sig.alg -> result Sig.pkey
let get_chain_public_signing_key c a = failwith "Not implemented"

abstract val get_chain_public_encryption_key : chain -> result RSAKey.pk
let get_chain_public_encryption_key c = failwith "Not implemented"

abstract val is_chain_for_signing : chain -> bool
let is_chain_for_signing c = failwith "Not implemented"

abstract val is_chain_for_key_encryption : chain -> bool
let is_chain_for_key_encryption c = failwith "Not implemented"

abstract val get_hint : chain -> option hint
let get_hint c = failwith "Not implemented"

abstract val validate_cert_chain : list Sig.alg  -> chain -> bool
let validate_cert_chain l c = failwith "Not implemented"
*)
