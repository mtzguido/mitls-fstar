module AEADProvider

open FStar.Heap
open FStar.HyperStack
open FStar.HyperStack.ST
open FStar.Seq
open FStar.Bytes

open Mem
open TLSConstants
open TLSInfo
open FStar.UInt32

module HS = FStar.HyperStack
module CC = CoreCrypto
module OAEAD = AEADOpenssl
module CAEAD = LowCProvider
module Plain = Crypto.Plain
module AE = Crypto.AEAD.Main
module CB = Crypto.Symmetric.Bytes
module U8 = FStar.UInt8
module E = EverCrypt

(* Forcing a dependency so that when building with the OpenSSL provider the
 * Crypto_Indexing module is in scope at this stage, henceby allowing us to
 * define Crypto_AEAD_Main_aead_state____. *)
let _ = Crypto.Indexing.rw2rw

let discard (b:bool) : ST unit (requires (fun _ -> True)) (ensures (fun h0 _ h1 -> h0 == h1)) = ()
let print (s:string) : ST unit (requires fun _ -> True) (ensures (fun h0 _ h1 -> h0 == h1)) =
  discard (IO.debug_print_string ("AEP| "^s^"\n"))
unfold let dbg : string -> ST unit (requires (fun _ -> True)) (ensures (fun h0 _ h1 -> h0 == h1)) =
  if DebugFlags.debug_AEP then print else (fun _ -> ())

include Specializations.Providers.AEAD

let prov () =
  match use_provider() with
  | OpenSSLProvider -> "OpenSSLProvider"
  | LowCProvider -> "LowCProvider"
  | LowProvider -> "LowProvider"

type u32 = FStar.UInt32.t

(***********************************************************************)

type id = i:id{~(PlaintextID? i) /\ AEAD? (aeAlg_of_id i)}
let alg (i:id) :aeadAlg = let AEAD aead _ = aeAlg_of_id i in aead
let evercrypt_aeadAlg_option_of_aead_cipher : aeadAlg -> option EverCrypt.aead_alg =
  function
  | CoreCrypto.AES_128_GCM -> Some EverCrypt.AES128_GCM
  | CoreCrypto.AES_256_GCM -> Some EverCrypt.AES256_GCM
  | CoreCrypto.CHACHA20_POLY1305 -> Some EverCrypt.CHACHA20_POLY1305
  | _ -> None
let aeadAlg_for_evercrypt (a:aeadAlg{Some? (evercrypt_aeadAlg_option_of_aead_cipher a)})
  : EverCrypt.aead_alg
  = Some?.v (evercrypt_aeadAlg_option_of_aead_cipher a)

// Real IVs must be created with the internal
// salting function below.
let iv_length i = CC.aeadRealIVSize (alg i)
abstract type iv (i:id) = lbytes (iv_length i)
let key_length i = CC.aeadKeySize (alg i)

// Salt is the static part of IVs
let salt_length (i:id) =
  match pv_of_id i with
  | TLS_1p3 -> iv_length i
  | _ ->
    match alg i with
    | CC.AES_128_GCM       -> 4
    | CC.AES_128_CCM       -> 4
    | CC.AES_128_CCM_8     -> 4
    | CC.AES_256_GCM       -> 4
    | CC.AES_256_CCM       -> 4
    | CC.AES_256_CCM_8     -> 4
    | CC.CHACHA20_POLY1305 -> 12

// Length of the explicit (sent on wire) IV
let explicit_iv_length (i:id) =
  match pv_of_id i with
  | TLS_1p3 -> 0
  | _ ->
    match alg i with
    | CC.AES_128_GCM       -> 8
    | CC.AES_128_CCM       -> 8
    | CC.AES_128_CCM_8     -> 8
    | CC.AES_256_GCM       -> 8
    | CC.AES_256_CCM       -> 8
    | CC.AES_256_CCM_8     -> 8
    | CC.CHACHA20_POLY1305 -> 0

type key  (i:id) = lbytes (key_length i)
type salt (i:id) = lbytes (salt_length i)

let pre_state (i:id) (r:rw) =
  match use_provider() with
  | OpenSSLProvider -> OAEAD.state i r
  | LowCProvider -> (CAEAD.aead_state * key i)
  | LowProvider -> EverCrypt.aead_state //NS: Used to be AE.aead_state i (Crypto.Indexing.rw2rw r)


let state (i:id) (r:rw) =
    pre_state i r * salt i

noextract inline_for_extraction
let as_openssl_state #i #r (s:state i r{use_provider()=OpenSSLProvider})
  : OAEAD.state i r
  = fst s

noextract inline_for_extraction
let as_lowc_state #i #r (s:state i r{use_provider()=LowCProvider})
  : CAEAD.aead_state * key i
  = fst s

noextract inline_for_extraction
let as_low_state #i #r (s:state i r{use_provider()=LowProvider})
  : EverCrypt.aead_state
  = fst s

let salt_of_state #i #r (s:state i r) : salt i = snd s

type writer i = s:state i Writer
type reader i = s:state i Reader

let noncelen (i:id) =
  match (pv_of_id i, alg i) with
  | (TLS_1p3, _) | (_, CC.CHACHA20_POLY1305) ->
    iv_length i
  | _ -> (iv_length i) - (salt_length i)

type nonce i = lbytes (noncelen i)

let coerce_iv (i:id) (b:lbytes (iv_length i)) : Tot (iv i) = b

let create_nonce (#i:id) (#rw:rw) (st:state i rw) (n:nonce i)
  : Tot (i:iv i) =
  let salt = salt_of_state st in
  match (pv_of_id i, alg i) with
  | (TLS_1p3, _) | (_, CC.CHACHA20_POLY1305) ->
    xor_ #(iv_length i) n salt
  | _ ->
    salt @| n

(* Necessary for injectivity of the nonce-to-IV construction in TLS 1.3 *)
#set-options "--z3rlimit 100 --initial_fuel 1 --max_fuel 1 --initial_ifuel 1 --max_ifuel 1 --admit_smt_queries true"
let lemma_nonce_iv (#i:id) (#rw:rw) (st:state i rw) (n1:nonce i) (n2:nonce i)
  : Lemma (create_nonce st n1 = create_nonce st n2 ==> n1 = n2)
  =
  let salt = salt_of_state st in
  match (pv_of_id i, alg i) with
  | (TLS_1p3, _) | (_, CC.CHACHA20_POLY1305) ->
    xor_idempotent (FStar.UInt32.uint_to_t (iv_length i)) n1 salt;
    xor_idempotent (FStar.UInt32.uint_to_t (iv_length i)) n2 salt
  | _ ->
    if (salt @| n1) = (salt @| n2) then
      () //lemma_append_inj salt n1 salt n2 //TODO bytes NS 09/27
#reset-options

let empty_log (#i:id) (#rw:rw) (st:state i rw) h =
  match use_provider() with
  | OpenSSLProvider -> OAEAD.empty_log (as_openssl_state st) h
  | _ -> True //TODO

let region (#i:id) (#rw:rw) (st:state i rw) =
  match use_provider() with
  | OpenSSLProvider -> OAEAD.State?.region (as_openssl_state st)
  | _ -> tls_region // TODO

let log_region (#i:id) (#rw:rw) (st:state i rw) : rgn =
  match use_provider() with
  | OpenSSLProvider ->
    OAEAD.State?.log_region (as_openssl_state st)
  | _ -> tls_region

let st_inv (#i:id) (#rw:rw) (st:state i rw) h = True //TODO

let genPost (#i:id) (parent:rgn) h0 (w:writer i) h1 =
  modifies_none h0 h1 /\
  extends (region w) parent /\
  fresh_region (region w) h0 h1 /\
  color (region w) = color parent /\
  empty_log w h1 /\
  st_inv w h1

module LB = LowStar.Buffer

#set-options "--max_fuel 0 --max_ifuel 1"
let gen (i:id) (r:rgn) : ST (state i Writer)
  (requires (fun h -> True))
  (ensures (genPost r))
  =
  let salt : salt i = CC.random (salt_length i) in
  match use_provider() with
  | OpenSSLProvider ->
    let st : OAEAD.state i Writer = OAEAD.gen r i in
    st, salt
  | LowCProvider ->
    assume false; // TODO
    let kv: key i = CC.random (CC.aeadKeySize (alg i)) in
    let st = CAEAD.aead_create (alg i) CAEAD.ValeAES kv in
    (st, kv), salt
  | LowProvider ->
    let len = CC.aeadKeySize (alg i) in
    let kv: key i = CC.random len in
    assume (FStar.UInt.size len 32);
    let len32 = UInt32.uint_to_t len in
    assume (len > 0);
    assume (is_eternal_region r);
    let kvb = LB.malloc r 0uy len32 in
    FStar.Bytes.store_bytes len32 kvb len32 kv;
    let h = get () in
    assume (Some? (evercrypt_aeadAlg_option_of_aead_cipher (alg i)));
    assume (EverCrypt.Specs.aead_create_pre h); //effectively False
    let st = EverCrypt.aead_create (aeadAlg_for_evercrypt (alg i)) kvb in
    let res : state i Writer = st, salt in
    let h1 = get () in
    assume (genPost r h res h1);
    res

let leak (#i:id) (#rw:rw) (st:state i rw)
  : ST (key i * salt i)
  (requires (fun h0 -> ~(authId i)))
  (ensures (fun h0 _ h1 -> modifies_none h0 h1))
  =
  match use_provider() with
  | OpenSSLProvider -> (OAEAD.leak (as_openssl_state st), salt_of_state st)
  | LowCProvider -> (snd (as_lowc_state st), salt_of_state st)
  | LowProvider ->
    assume (false);
    assume(~(Flag.prf i));
    let len = CC.aeadKeySize (alg i) in
    let kv: key i = CC.random len in
    kv, snd st //TODO: FIXME! We do not have a leak yet in EverCrypt

// ADL TODO
// There is an issue connecting the stateful encryption in miTLS
// to the low-level crypto which currently shares the region between
// the reader and writer (this is not sound for some buffers in that
// region, for instance, the writer may write the the reader's key buffer)
#set-options "--z3rlimit 100 --initial_fuel 1 --max_fuel 1 --initial_ifuel 1 --max_ifuel 1 --admit_smt_queries true"
let genReader (parent:rgn) (#i:id) (st:writer i) : ST (reader i)
  (requires (fun h -> HS.disjoint parent (region st)))
  (ensures (fun h0 _ h1 -> modifies_none h0 h1))
  =
  match use_provider() with
  | OpenSSLProvider ->
    // CoreCrypto state is in an external region
    OAEAD.genReader parent (as_openssl_state st), salt_of_state st
  | LowCProvider ->
    assume false;
    as_lowc_state st, salt_of_state st
  | LowProvider -> st //TODO: EverCrypt.fsti does not provide a genReader
#reset-options

#reset-options "--z3rlimit 100 --initial_fuel 1 --max_fuel 1 --initial_ifuel 1 --max_ifuel 1"
let coerce (i:id) (r:rgn) (k:key i) (s:salt i)
  : ST (state i Writer)
  (requires (fun h -> ~(authId i)))
  (ensures (fun h0 _ h1 -> modifies_none h0 h1))
  =
  let w =
    match use_provider() with
    | OpenSSLProvider ->
      OAEAD.coerce r i k, s
    | LowCProvider ->
      let (st:CAEAD.aead_state) = CAEAD.aead_create (alg i) CAEAD.ValeAES k in
      let (psi:pre_state i Writer) = (st, k) in
        psi, s
    | LowProvider ->
      assume (AE.keylen i = len k);
      assume (~ (Flag.prf i));
      assume(false);
      let len = length k in
      let len32 = FStar.UInt32.uint_to_t len in
      assume (is_eternal_region r);
      let kvb = LB.malloc r 0uy len32 in
      FStar.Bytes.store_bytes len32 kvb len32 k;
      let st = EverCrypt.aead_create (aeadAlg_for_evercrypt (alg i)) kvb in
      let res : state i Writer = st, s in
      res in
  dbg ((prov())^": COERCE(K="^(hex_of_bytes k)^")");
  w
#reset-options

type plainlen = n:nat{n <= max_TLSPlaintext_fragment_length}
(* irreducible *)
type plain (i:id) (l:plainlen) = b:lbytes l
let repr (#i:id) (#l:plainlen) (p:plain i l) : Tot (lbytes l) = p

let adlen i = match pv_of_id i with
  | TLS_1p3 -> 0 | _ -> 13
type adata i = lbytes (adlen i)

let taglen i = CC.aeadTagSize (alg i)
let cipherlen i (l:plainlen) : n:nat{n >= taglen i} = l + taglen i
type cipher i (l:plainlen) = lbytes (cipherlen i l)

let fresh_iv (#i:id{authId i}) (w:writer i) (iv:iv i) h =
  match use_provider() with
  | OpenSSLProvider -> OAEAD.fresh_iv #i (as_openssl_state w) iv h
  |  _ -> True // TODO

let logged_iv (#i:id{authId i}) (#l:plainlen) (#rw:rw) (s:state i rw) (iv:iv i)
              (ad:adata i) (p:plain i l) (c:cipher i l) h =
  match use_provider() with
  | OpenSSLProvider -> OAEAD.logged_iv #i #rw (as_openssl_state s) iv (OAEAD.Entry ad p c) h
  | _ -> True

// ADL Jan 3: PlanA changes TODO
open EverCrypt.Helpers
module LM = LowStar.Modifies

#set-options "--max_fuel 0 --max_ifuel 0"
let from_bytes (b:bytes{UInt.fits (length b) 32 /\ length b <> 0}) : StackInline uint8_p
  (requires (fun h0 -> True))
  (ensures  (fun h0 buf h1 ->
    LB.(modifies loc_none h0 h1) /\
    LB.live h1 buf /\
    LB.unused_in buf h0 /\
    LB.length buf = length b /\
    Bytes.reveal b `Seq.equal` LB.as_seq h1 buf))
  =
  let h0 = get () in
  let len = FStar.UInt32.uint_to_t (length b) in
  let lb = LB.alloca 0uy len in
  FStar.Bytes.store_bytes len lb len b;
  let h1 = get () in
  LB.(modifies_only_not_unused_in loc_none h0 h1);
  lb

#set-options "--admit_smt_queries true"
let encrypt (#i:id) (#l:plainlen) (w:writer i) (iv:iv i) (ad:adata i) (plain:plain i l)
  : ST (cipher:cipher i l)
       (requires (fun h ->
                    st_inv w h /\
                    (authId i ==> (Flag.prf i /\ fresh_iv #i w iv h)) /\
                    FStar.UInt.size (length ad) 32 /\
                    FStar.UInt.size l 32))
       (ensures (fun h0 cipher h1 -> modifies_one (log_region w) h0 h1))
  =
    match use_provider() with
    | OpenSSLProvider -> OAEAD.encrypt (as_openssl_state w) iv ad plain
    | LowCProvider ->
      let st, _ = as_lowc_state w in
      assume(CAEAD.alg st = alg i); // assume val in the .fst
      CAEAD.aead_encrypt st iv ad plain
    | LowProvider ->
      let st = as_low_state w in
      let adlen = uint_to_t (length ad) in
      let plainlen = uint_to_t l in
      let taglen = uint_to_t (taglen i) in
      let cipherlen = plainlen +^ taglen in
      assume(AE.safelen i (v plainlen) = true); // TODO
      push_frame ();
      let ad = from_bytes ad in
      let cipher_tag = LB.alloca 0uy cipherlen in
      let cipher = LB.sub cipher_tag 0ul plainlen in
      let tag = LB.sub cipher_tag plainlen taglen in
      let iv = from_bytes iv in
      let plain =
        if not (TLSInfo.safeId i)
        then from_bytes plain
        else LB.alloca 0uy plainlen
      in
      EverCrypt.aead_encrypt st iv ad adlen plain plainlen cipher tag;
      let cipher_tag_res = FStar.Bytes.of_buffer cipherlen cipher in
      pop_frame();
      cipher_tag_res

  (*
  let r =
    if debug then
      let ivh = hex_of_bytes iv in
      let adh = hex_of_bytes ad in
      let ph = hex_of_bytes plain in
      let ch = hex_of_bytes cipher in
      IO.debug_print_string ((prov())^": ENC[IV="^ivh^",AD="^adh^",PLAIN="^ph^"] = "^ch^"\n")
    else false in
  if r then cipher else cipher
*)

let decrypt (#i:id) (#l:plainlen) (st:reader i) (iv:iv i) (ad:adata i) (cipher:cipher i l)
  : ST (co:option (plain i l))
       (requires (fun _ -> True))
//  (requires (fun _ ->
//    FStar.UInt.size (length ad) 32
//    /\ FStar.UInt.size (length cipher) 32
//    /\ length cipher >= CC.aeadTagSize (alg i))
       (ensures (fun h0 plain h1 ->
                   modifies_none h0 h1))
  =
    match use_provider() with
    | OpenSSLProvider -> OAEAD.decrypt (as_openssl_state st) iv ad cipher
    | LowCProvider -> CAEAD.aead_decrypt (fst (as_lowc_state st)) iv ad cipher
    | LowProvider ->
      push_frame();
      let st = as_low_state st in
      let iv = from_bytes iv in
      let adlen = uint_to_t (length ad) in
      let ad = from_bytes ad in
      let plainlen = uint_to_t l in
      let taglen = uint_to_t (taglen i) in
      let cipher_tag_buf = from_bytes cipher in
      let cipher = LB.sub cipher_tag_buf 0ul plainlen in
      let tag = LB.sub cipher_tag_buf plainlen taglen in
      let plain = LB.alloca 0uy plainlen in
      let ok = EverCrypt.aead_decrypt st iv ad adlen plain plainlen cipher tag in
      let ret =
        if ok = 0ul
        then Some (FStar.Bytes.of_buffer plainlen plain)
        else None
      in
      pop_frame();
      ret

  (*
  let r =
    if debug then
      let ivh = hex_of_bytes iv in
      let adh = hex_of_bytes ad in
      let ch = hex_of_bytes cipher in
      let ph =
        match plain with
        | None -> "FAIL"
        | Some p -> hex_of_bytes p
        in
      IO.debug_print_string ((prov())^": DECRYPT[IV="^ivh^",AD="^adh^",C="^ch^"] = "^ph^"\n")
    else false in
  if r then plain else plain
 *)


(*
/// Agility:
/// - for AEAD, we need a pair of algorithms for the cipher and for UFCMA---use Crypto.Indexing.fsti;
/// - for StreamAE, we additionallly need the PV (to control the length of the static IV).
///
/// We keep these parameters in AEADProvider and StreamAE instances, respectively.

type aeadAlg // fixme.

// TODO: add the two regions of AEAD.fsti, used only ideally (hence coerce is ~pure)
type info (ip: ipkg) (aeadAlg_of_i: i:ip.IK.t -> aeadAlg) (i:ip.t) = a:aeadAlg {a = aeadAlg_of_i i}

open IK
unfold let localpkg
  (ip: ipkg)
  (aeadAlg_of_i: i:ip.IK.t -> aeadAlg)
  :
  p: IK.local_pkg ip {IK.LocalPkg?.info #ip p == info1 ip ha_of_i good_of_i}
=
    IK.LocalPkg
      (fun (i:ip.IK.t {ip.IK.registered i}) -> writer ip i)
      (info ip aeadAlg_of_i)
      (fun #_ u -> aeadLen u)
      Flags.ideal_aead
      // local footprint
      (fun #i (k:writer ip i) -> Set.empty (*17-11-24 regions for the PRF and the log *)  )
      // local invariant
      (fun #_ k h -> True)
      (fun r i h0 k h1 -> ())
      // create/coerce postcondition
      (fun #i u k h1 -> k.u == u (*17-11-24  /\ fresh_subregion (region k) u.parent h0 h1 *) )
      (fun #i u k h1 r h2 -> ())
      (create ip aeadAlg_of_i)
      (coerceT ip aeadAlg_of_i)
      (coerce ip aeadAlg_of_i)

let mk_pkg (ip:ipkg) (aeadAlg_of_i: ip.t -> aeadAlg): ST (pkg ip)
  (requires fun h0 -> True)
  (ensures fun h0 p h1 ->
    //17-12-01 we also need freshness and emptyness of the new table + local packaging
    modifies_mem_table p.define_table h0 h1 /\
    p.package_invariant h1)
=
  memoization_ST #ip (localpkg ip aeadAlg_of_i)

// we may want to provide TLS-specific encrypt, decrypt... partially applied e.g. [encrypt ii aeadAlg_of_i]


unfold let localpkg_IV
// TODO adapting local_raw_pkg

// TODO ensure the flag is set only when multiplexing to the verified implementation
*)
