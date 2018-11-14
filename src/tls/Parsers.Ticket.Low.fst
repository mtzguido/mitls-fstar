module Parsers.Ticket.Low
open Parsers.ProtocolVersion
open Parsers.CipherSuite
open Parsers.Boolean
open Parsers.TicketContents12
open Parsers.TicketContents13
open Parsers.TicketContents

module HS = FStar.HyperStack
module LP = LowParse.Low
module LPT = LowParse.SLow.Tac.Enum
module LPB = LowParse.Spec.Bytes
module U32 = FStar.UInt32

friend Parsers.ProtocolVersion
friend Parsers.CipherSuite
friend Parsers.Boolean
friend Parsers.TicketContents12
friend Parsers.TicketContents13

let write_protocolVersion =
  lemma_synth_protocolVersion_inj ();
  lemma_synth_protocolVersion_inv ();
  LP.write_synth
    (LP.write_maybe_enum_key LP.write_u16 protocolVersion_enum (_ by (LPT.enum_repr_of_key_tac protocolVersion_enum)))
    synth_protocolVersion
    synth_protocolVersion_inv
    (fun x -> synth_protocolVersion_inv x)
    ()

let write_cipherSuite =
  lemma_synth_cipherSuite_inj ();
  lemma_synth_cipherSuite_inv ();
  LP.write_synth
    (LP.write_maybe_enum_key LP.write_u16 cipherSuite_enum (_ by (LPT.enum_repr_of_key_tac cipherSuite_enum)))
    synth_cipherSuite
    synth_cipherSuite_inv
    (fun x -> synth_cipherSuite_inv x)
    ()

let write_boolean =
  lemma_synth_boolean_inj ();
  lemma_synth_boolean_inv ();
  LP.write_synth
    (LP.write_enum_key LP.write_u8 boolean_enum (_ by (LPT.enum_repr_of_key_tac boolean_enum)))
    synth_boolean
    synth_boolean_inv
    (fun x -> synth_boolean_inv x)
    ()

#reset-options "--max_fuel 0 --max_ifuel 0"

let valid_ticketContents12_intro h input pos =
  synth_ticketContents12_injective();
  LP.valid_synth h ticketContents12'_parser synth_ticketContents12 input pos;
  LP.valid_nondep_then h (protocolVersion_parser `LP.nondep_then` cipherSuite_parser `LP.nondep_then` boolean_parser) ticketContents12_master_secret_parser input pos;
  LP.valid_nondep_then h (protocolVersion_parser `LP.nondep_then` cipherSuite_parser) boolean_parser input pos;
  LP.valid_nondep_then h protocolVersion_parser cipherSuite_parser input pos

#set-options "--z3rlimit 16 --print_z3_statistics"

let valid_ticketContents13_intro h input pos =
  let cs = LP.contents cipherSuite_parser h input pos in
  let pos1 = LP.get_valid_pos cipherSuite_parser h input pos in
  let rms = LP.contents ticketContents13_rms_parser h input pos1 in
  let pos2 = LP.get_valid_pos ticketContents13_rms_parser h input pos1 in
  let nonce = LP.contents ticketContents13_nonce_parser h input pos2 in
  let pos3 = LP.get_valid_pos ticketContents13_nonce_parser h input pos2 in
  let creation_time = LP.contents LP.parse_u32 h input pos3 in
  let pos4 = LP.get_valid_pos LP.parse_u32 h input pos3 in
  let age_add = LP.contents LP.parse_u32 h input pos4 in
  let pos5 = LP.get_valid_pos LP.parse_u32 h input pos4 in
  let custom_data = LP.contents ticketContents13_custom_data_parser h input pos5 in
  let pos6 = LP.get_valid_pos ticketContents13_custom_data_parser h input pos5 in
  LP.valid_nondep_then_intro h cipherSuite_parser ticketContents13_rms_parser
  input pos;
  LP.valid_nondep_then_intro h (  cipherSuite_parser
  `LP.nondep_then` ticketContents13_rms_parser)
  ticketContents13_nonce_parser
  input pos;
  LP.valid_nondep_then_intro h (  cipherSuite_parser
  `LP.nondep_then` ticketContents13_rms_parser
  `LP.nondep_then` ticketContents13_nonce_parser
  ) LP.parse_u32
  input pos;
  LP.valid_nondep_then_intro h (  cipherSuite_parser
  `LP.nondep_then` ticketContents13_rms_parser
  `LP.nondep_then` ticketContents13_nonce_parser
  `LP.nondep_then` LP.parse_u32
  ) LP.parse_u32
  input pos;
  LP.valid_nondep_then_intro h (  cipherSuite_parser
  `LP.nondep_then` ticketContents13_rms_parser
  `LP.nondep_then` ticketContents13_nonce_parser
  `LP.nondep_then` LP.parse_u32
  `LP.nondep_then` LP.parse_u32
  ) ticketContents13_custom_data_parser input pos;
  assert_norm (ticketContents13' == LP.get_parser_type (
    cipherSuite_parser
    `LP.nondep_then` ticketContents13_rms_parser
    `LP.nondep_then` ticketContents13_nonce_parser
    `LP.nondep_then` LP.parse_u32
    `LP.nondep_then` LP.parse_u32
    `LP.nondep_then` ticketContents13_custom_data_parser
  )); // because of refinements
  synth_ticketContents13_injective ();
  LP.valid_synth_intro h ticketContents13'_parser synth_ticketContents13 input pos