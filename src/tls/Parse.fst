module Parse

open FStar.Error
open FStar.Bytes
open FStar.HyperStack.All

open TLSError

include Mem // temporary, for code opening only TLSConstants

module B = FStar.Bytes
module HS = FStar.HyperStack
module ST = FStar.HyperStack.ST

(** This file will go away when all parsers have been ported to LowParse *)


// basic parsing and formatting---an attempt at splitting TLSConstant.

type pinverse_t (#a:Type) (#b:Type) ($f:(a -> Tot b)) = b -> Tot (result a)

unfold type lemma_inverse_g_f (#a:Type) (#b:Type) ($f:a -> Tot b) ($g:b -> Tot (result a)) (x:a) =
  g (f x) == Correct x

unfold type lemma_pinverse_f_g (#a:Type) (#b:Type) (r:b -> b -> Type) ($f:a -> Tot b) ($g:b -> Tot (result a)) (y:b) =
  Correct? (g y) ==> r (f (Correct?._0 (g y))) y


(** Transforms a sequence of natural numbers into bytes *)
val bytes_of_seq: n:nat{B.repr_bytes n <= 8 } -> Tot (b:B.bytes{B.length b <= 8})
let bytes_of_seq sn = B.bytes_of_int 8 sn

(** Transforms bytes into a sequence of natural numbers *)
val seq_of_bytes: b:B.bytes{ B.length b <= 8 } -> Tot nat
let seq_of_bytes b = B.int_of_bytes b

(** Transform and concatenate a natural number to bytes *)
val vlbytes: lSize:nat{lSize <= 32} -> b:B.bytes{B.repr_bytes (B.length b) <= lSize} -> Tot (r:B.bytes{B.length r = lSize + B.length b})
let vlbytes lSize b = 
  let (i:nat) = B.length b in
  let bi = B.bytes_of_int lSize i in
  assume (UInt.fits (length bi + length b) 32);
  bi @| b

// avoiding explicit applications of the representation lemmas
let vlbytes1 (b:B.bytes {B.length b < pow2 8}) = B.lemma_repr_bytes_values (B.length b); vlbytes 1 b
let vlbytes2 (b:B.bytes {B.length b < pow2 16}) = B.lemma_repr_bytes_values (B.length b); vlbytes 2 b

val vlbytes_trunc: lSize:nat{lSize <= 32} -> b:B.bytes ->
  extra:nat{B.repr_bytes (B.length b + extra) <= lSize} ->
  r:B.bytes{B.length r == lSize + B.length b}
let vlbytes_trunc lSize b extra =
  let bex = B.length b + extra in
  let q = B.bytes_of_int lSize bex in
  assume (UInt.fits (length q + length b) 32);
  q @| b

let vlbytes_trunc_injective
  (lSize: nat)
  (b1: B.bytes)
  (extra1: nat { B.repr_bytes (B.length b1 + extra1) <= lSize } )
  (s1: B.bytes)
  (b2: B.bytes)
  (extra2: nat { B.repr_bytes (B.length b2 + extra2) <= lSize } )
  (s2: B.bytes)
: Lemma
  (requires (lSize <= 32 /\ (let q = vlbytes_trunc lSize b1 extra1 in 
                             UInt.fits (length q + length s1) 32 /\
                             (let q2 = vlbytes_trunc lSize b2 extra2 in
                              UInt.fits (length q2 + length s2) 32 /\
                              (q @| s1) = q2 @| s2))))
  (ensures (B.length b1 + extra1 == B.length b2 + extra2 /\ b1 @| s1 == b2 @| s2))
= admit()
  // let l1 = B.bytes_of_int lSize (B.length b1 + extra1) in
  // let l2 = B.bytes_of_int lSize (B.length b2 + extra2) in
  // B.append_assoc l1 b1 s1;
  // B.append_assoc l2 b2 s2;
  // B.lemma_append_inj l1 (b1 @| s1) l2 (b2 @| s2);
  // B.int_of_bytes_of_int lSize (B.length b1 + extra1);
  // B.int_of_bytes_of_int lSize (B.length b2 + extra2)

(** Lemmas associated to bytes manipulations *)
val lemma_vlbytes_len : i:nat{i <= 32} -> b:B.bytes{B.repr_bytes (B.length b) <= i}
  -> Lemma (ensures (B.length (vlbytes i b) = i + B.length b))
let lemma_vlbytes_len i b = ()


val lemma_vlbytes_inj_strong : i:nat{i <= 32}
  -> b:B.bytes{B.repr_bytes (B.length b) <= i}
  -> s:B.bytes
  -> b':B.bytes{B.repr_bytes (B.length b') <= i}
  -> s':B.bytes
  -> Lemma (requires (let vb = vlbytes i b in 
                      let vb' = vlbytes i b' in
                      (UInt.fits (length vb + length s) 32) /\ 
                      (UInt.fits (length vb' + length s') 32) /\ 
                      (vb @| s) = (vb' @| s')))
          (ensures (b == b' /\ s == s'))

let lemma_vlbytes_inj_strong i b s b' s' = admit()
  // let l = B.bytes_of_int i (B.length b) in
  // let l' = B.bytes_of_int i (B.length b') in
  // B.append_assoc l b s;
  // B.append_assoc l' b' s';
  // B.lemma_append_inj l (b @| s) l' (b' @| s');
  // B.int_of_bytes_of_int i (B.length b);
  // B.int_of_bytes_of_int i (B.length b');
  // B.lemma_append_inj b s b' s'

val lemma_vlbytes_inj : i:nat{i <= 32}
  -> b:B.bytes{B.repr_bytes (B.length b) <= i}
  -> b':B.bytes{B.repr_bytes (B.length b') <= i}
  -> Lemma (requires ((vlbytes i b) = (vlbytes i b')))
          (ensures (b == b'))

let lemma_vlbytes_inj i b b' =
  lemma_vlbytes_inj_strong i b B.empty_bytes b' B.empty_bytes

val vlbytes_length_lemma: n:nat{n <= 32} -> a:B.bytes{B.repr_bytes (B.length a) <= n} -> b:B.bytes{B.repr_bytes (B.length b) <= n} ->
  Lemma (requires ((B.slice (vlbytes n a) 0ul (FStar.UInt32.uint_to_t n)) = (B.slice (vlbytes n b) 0ul (FStar.UInt32.uint_to_t n))))
        (ensures (B.length a = B.length b))

let vlbytes_length_lemma n a b = admit()

#set-options "--max_ifuel 1 --initial_ifuel 1 --max_fuel 0 --initial_fuel 0"   //need to reason about length

val vlsplit: lSize:nat{lSize <= 4}
  -> vlb:B.bytes{lSize <= B.length vlb}
  -> Tot (result (b:(B.bytes * B.bytes){
        B.repr_bytes (B.length (fst b)) <= lSize /\
        (let vb = vlbytes lSize (fst b) in
         (UInt.fits (length vb + length (snd b)) 32) /\         
         vlb == (vb @| (snd b)))}))

#set-options "--max_ifuel 2 --initial_ifuel 2"
let vlsplit lSize vlb =
  let (vl,b) = B.split vlb (FStar.UInt32.uint_to_t lSize) in
  let l = B.int_of_bytes vl in
  if l <= B.length b
  then begin
    let ln = B.len b in
    assert (l <= B.length b);
    let (u, v) = B.split b ln in
//    B.append_assoc vl u v; //TODO
    assume (length u < length b);
    assume (length v < length b);
   Correct (u,v)
   end
  else Error(AD_decode_error, perror __SOURCE_FILE__ __LINE__ "")

val vlparse: lSize:nat{lSize <= 4} -> vlb:B.bytes{lSize <= B.length vlb}
  -> Pure (r:result B.bytes)
  (requires (True))
  (ensures fun r -> Correct? r ==>
    (let b = Correct?._0 r in 
     B.repr_bytes (B.length b) <= lSize ///\ 
     //vlb = (vlbytes lSize b)
     ))
let vlparse lSize vlb =
  let vl,b = B.split vlb (FStar.UInt32.uint_to_t lSize) in
  if B.int_of_bytes vl = B.length b then Correct b
  else Error(AD_decode_error, perror __SOURCE_FILE__ __LINE__ "")

val vlparse_vlbytes: lSize:nat{lSize <= 4} -> vlb:B.bytes{B.repr_bytes (B.length vlb) <= lSize} -> Lemma
  (requires (True))
  (ensures (vlparse lSize (vlbytes lSize vlb) == Correct vlb))
  [SMTPat (vlparse lSize (vlbytes lSize vlb))]
#reset-options "--initial_ifuel 2 --initial_fuel 2"
let vlparse_vlbytes lSize vlb =
  let b' = vlbytes lSize vlb in
  assert(b' = B.bytes_of_int lSize (B.length vlb) @| vlb);
  let vl, b = B.split b' (FStar.UInt32.uint_to_t lSize) in
//  B.lemma_append_inj vl b (B.bytes_of_int lSize (B.length vlb)) vlb; //TODO
  assume (vl = (B.bytes_of_int lSize (B.length vlb)));
//  B.int_of_bytes_of_int lSize (B.length vlb); //TODO
  let x = vlparse lSize b' in
//  let b'' = Correct?._0 x in
  assert(x == vlparse lSize (vlbytes lSize vlb));
  admit()

val uint16_of_bytes:
  b:B.bytes{B.length b == 2} ->
  n:UInt16.t{B.repr_bytes (UInt16.v n) <= 2 /\ B.bytes_of_int 2 (UInt16.v n) == b}

let uint16_of_bytes b =
  let n = B.int_of_bytes b in
  assert_norm (pow2 16 == 65536);
  B.lemma_repr_bytes_values n;
  // B.int_of_bytes_of_int 2 n; //TODO
  let r = UInt16.uint_to_t n in
  assert(UInt16.v r = n);
  assert(B.repr_bytes (UInt16.v r) <= 2);
  r

val uint32_of_bytes:
  b:B.bytes{B.length b == 4} ->
  n:UInt32.t{B.repr_bytes (UInt32.v n) <= 4 /\ B.bytes_of_int 4 (UInt32.v n) == b}

let uint32_of_bytes b =
  let n = B.int_of_bytes b in
  assert_norm (pow2 32 == 4294967296);
  B.lemma_repr_bytes_values n;
  UInt32.uint_to_t n

let bytes_of_uint32 (n:UInt32.t) : Tot (B.lbytes 4) =
  FStar.Bytes.bytes_of_int32 n

let bytes_of_uint16 (n:UInt16.t) : Tot (B.lbytes 2) =
  let n = UInt16.v n in
  B.lemma_repr_bytes_values n;
  B.bytes_of_int 2 n

let cbyte (b:bytes{length b >= 1}) = FStar.Bytes.index b 0
let cbyte2 (b:bytes{length b >= 2}) = (FStar.Bytes.index b 0, FStar.Bytes.index b 1)
