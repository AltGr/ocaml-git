(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open OUnit
open Test_common
open Lwt
open GitTypes

type t = {
  name : string;
  init : unit -> unit Lwt.t;
  clean: unit -> unit Lwt.t;
  store: (module S);
}

let unit () =
  return_unit

module Make (S: S) = struct

  module Common = Make(S)
  open Common
  open S

  let run x test =
    try Lwt_unix.run (x.init () >>= test >>= x.clean)
    with e ->
      Lwt_unix.run (x.clean ());
      raise e

  let test_values x () =
    let v1 = blob (Blob.of_string "foo") in
    let k1 = key v1 in
    let v2 = blob (Blob.of_string "") in
    let k2 = key v2 in
    let test () =
      create () >>= fun t    ->
      write t v1 >>= fun k1'  ->
      assert_key_equal "k1" k1 k1';
      write t v1 >>= fun k1'' ->
      assert_key_equal "k1" k1 k1'';
      write t v2 >>= fun k2'  ->
      assert_key_equal "k2" k2 k2';
      write t v2 >>= fun k2'' ->
      assert_key_equal "k2" k2 k2'';
      read t k1  >>= fun v1'  ->
      assert_value_opt_equal "v1" (Some v1) v1';
      read t k2  >>= fun v2'  ->
      assert_value_opt_equal "v2" (Some v2) v2';
      return_unit
    in
    run x test

  let test_trees x () =
    let v1 = blob (Blob.of_string "foo") in
    let v2 = blob (Blob.of_string "") in
    let kv1 = key v1 in
    let test () =
      create () >>= fun t  ->
      let find = Git.find ~succ:(succ t) in
      let find_exn = Git.find_exn ~succ:(succ t) in

      let t1 = tree [
        { Tree.perm = `normal;
          file = "a";
          node = kv1 }
      ] in
      (* Create a node containing t1 -a-> v1 *)
      write t t1    >>= fun k1  ->
      write t t1    >>= fun k1' ->
      assert_key_equal "k1.1" k1 k1';
      read_exn t k1 >>= fun t1  ->
      write t t1    >>= fun k1''->
      assert_key_equal "k1.2" k1 k1'';

      (* Create the tree t2 -b-> t1 -a-> v1 *)
      let t2 = tree [
          { Tree.perm = `dir;
            file = "b";
            node = k1 }
        ] in
      write t t2     >>= fun k2  ->
      write t t2     >>= fun k2' ->
      assert_key_equal "k2.1" k2 k2';
      read_exn t k2  >>= fun t2  ->
      write t t2     >>= fun k2''->
      assert_key_equal "k2.2" k2 k2'';
      Git.find_exn ~succ:(succ t) k2 ["b"] >>= fun k1_ ->
      assert_key_equal "k1.1" k1 k1_;

      (* Create the tree t3 -a-> t2 -b-> t1 -a-> v1 *)
      let t3 = tree [
          { Tree.perm = `dir;
            file = "a";
            node = k2; }
        ] in
      write t t3         >>= fun k3  ->
      write t t3         >>= fun k3' ->
      assert_key_equal "k3.1" k3 k3';
      read_exn t k3      >>= fun t3  ->
      write t t3         >>= fun k3''->
      assert_key_equal "k3.2" k3 k3'';
      find_exn k3 ["a"]  >>= fun k2_ ->
      assert_key_equal "k2.1" k2 k2_;
      find_exn k2_ ["b"] >>= fun k1_ ->
      assert_key_equal "k1.2" k1 k1_;
      find k3 ["a";"b"]  >>= fun k1_ ->
      assert_key_opt_equal "k1.3" (Some k1) k1_;

      find k1 ["a"]         >>= fun kv11 ->
      assert_key_opt_equal "kv1.1" (Some kv1) kv11;
      find k2 ["b";"a"]     >>= fun kv12 ->
      assert_key_opt_equal "kv1.2" (Some kv1) kv12;
      find k3 ["a";"b";"a"] >>= fun kv13 ->
      assert_key_opt_equal "kv1.3" (Some kv1) kv13;

      (* Create the tree t4 -a-> t2 -b-> t1 -a-> v1
                           \-c-> t4 -> v2 *)
      let t4 = tree [
          { Tree.perm = `exec;
            file = "c";
            node = key v2; };
          { Tree.perm = `dir;
            file = "a";
            node = k2; }
        ] in
      write t t4                  >>= fun k4 ->
      assert_key_equal "k4" k4 (key t4);
      read_exn t k4               >>= fun t4' ->
      assert_value_equal "t4" t4 t4';
      find_exn k4 ["a"; "b"; "a"] >>= fun kv1' ->
      assert_key_equal "kv1.4" kv1 kv1';
      find_exn k4 ["c"]           >>= fun kv2' ->
      assert_key_equal "kv2" (key v2) kv2';
      return_unit
    in
    run x test

(*
  let test_revisions x () =
    let v1 = Value.of_bytes "foo" in
    let test () =
      create () >>= fun t   ->
      let tree = tree_store t in
      let revision = revision_store t in

      (* t3 -a-> t2 -b-> t1(v1) *)
      Tree.tree tree ~value:v1 [] >>= fun k1  ->
      Tree.read_exn tree k1       >>= fun t1  ->
      Tree.tree tree ["a", t1]    >>= fun k2  ->
      Tree.read_exn tree k2       >>= fun t2  ->
      Tree.tree tree ["b", t2]    >>= fun k3  ->
      Tree.read_exn tree k3       >>= fun t3  ->

      (* r1 : t2 *)
      Revision.revision revision ~tree:t2 [] >>= fun kr1 ->
      Revision.revision revision ~tree:t2 [] >>= fun kr1'->
      assert_key_equal "kr1" kr1 kr1';
      Revision.read_exn revision kr1         >>= fun r1  ->

      (* r1 -> r2 : t3 *)
      Revision.revision revision ~tree:t3 [r1] >>= fun kr2  ->
      Revision.revision revision ~tree:t3 [r1] >>= fun kr2' ->
      assert_key_equal "kr2" kr2 kr2';
      Revision.read_exn revision kr2           >>= fun r2   ->

      Revision.list revision kr1 >>= fun kr1s ->
      assert_keys_equal "g1" [kr1] kr1s;

      Revision.list revision kr2 >>= fun kr2s ->
      assert_keys_equal "g2" [kr1; kr2] kr2s;

     return_unit
    in
    run x test

  let test_tags x () =
    let t1 = Tag.of_string "foo" in
    let t2 = Tag.of_string "bar" in
    let v1 = Value.of_bytes "foo" in
    let k1 = key v1 in
    let v2 = Value.of_bytes "" in
    let k2 = key v2 in
    let test () =
      create ()              >>= fun t   ->
      let tag = tag_store t in
      Tag.update tag t1 k1 >>= fun ()  ->
      Tag.read   tag t1    >>= fun k1' ->
      assert_key_opt_equal "t1" (Some k1) k1';
      Tag.update tag t2 k2 >>= fun ()  ->
      Tag.read   tag t2    >>= fun k2' ->
      assert_key_opt_equal "t2" (Some k2) k2';
      Tag.update tag t1 k2 >>= fun ()   ->
      Tag.read   tag t1    >>= fun k2'' ->
      assert_key_opt_equal "t1-after-update" (Some k2) k2'';
      Tag.list   tag t1    >>= fun ts ->
      assert_tags_equal "list" [t1; t2] ts;
      Tag.remove tag t1    >>= fun () ->
      Tag.read   tag t1    >>= fun empty ->
      assert_key_opt_equal "empty" None empty;
      Tag.list   tag t1    >>= fun t2' ->
      assert_tags_equal "all-after-remove" [t2] t2';
      return_unit
    in
    run x test

  let test_stores x () =
    let v1 = Value.of_bytes "foo" in
    let v2 = Value.of_bytes "" in
    let test () =
      create ()             >>= fun t   ->
      update t ["a";"b"] v1 >>= fun ()  ->

      mem t ["a";"b"]       >>= fun b1  ->
      assert_bool_equal "mem1" true b1;
      mem t ["a"]           >>= fun b2  ->
      assert_bool_equal "mem2" false b2;
      read_exn t ["a";"b"]  >>= fun v1' ->
      assert_value_equal "v1.1" v1 v1';
      snapshot t            >>= fun r1  ->

      update t ["a";"c"] v2 >>= fun ()  ->
      mem t ["a";"b"]       >>= fun b1  ->
      assert_bool_equal "mem3" true b1;
      mem t ["a"]           >>= fun b2  ->
      assert_bool_equal "mem4" false b2;
      read_exn t ["a";"b"]  >>= fun v1' ->
      assert_value_equal "v1.1" v1 v1';
      mem t ["a";"c"]       >>= fun b1  ->
      assert_bool_equal "mem5" true b1;
      read_exn t ["a";"c"]  >>= fun v2' ->
      assert_value_equal "v1.1" v2 v2';

      remove t ["a";"b"]    >>= fun ()  ->
      read t ["a";"b"]      >>= fun v1''->
      assert_value_opt_equal "v1.2" None v1'';
      revert t r1           >>= fun ()  ->
      read t ["a";"b"]      >>= fun v1''->
      assert_value_opt_equal "v1.3" (Some v1) v1'';
      list t ["a"]          >>= fun ks  ->
      assert_paths_equal "path" [["a";"b"]] ks;
      return_unit
    in
    run x test

  let test_sync x () =
    let v1 = Value.of_bytes "foo" in
    let v2 = Value.of_bytes "" in
    let test () =
      create ()              >>= fun t1 ->
      update t1 ["a";"b"] v1 >>= fun () ->
      snapshot t1            >>= fun r1 ->
      update t1 ["a";"c"] v2 >>= fun () ->
      snapshot t1            >>= fun r2 ->
      update t1 ["a";"d"] v1 >>= fun () ->
      snapshot t1            >>= fun r3 ->
      output t1 "full"       >>= fun () ->
      export t1 [r3]         >>= fun partial ->
      export t1 []           >>= fun full    ->

      (* Restart a fresh store and import everything in there. *)
      x.clean ()             >>= fun () ->
      x.init ()              >>= fun () ->
      create ()              >>= fun t2 ->

      import t2 partial      >>= fun () ->
      revert t2 r3           >>= fun () ->
      output t2 "partial"    >>= fun () ->

      mem t2 ["a";"b"]       >>= fun b1 ->
      assert_bool_equal "mem-ab" true b1;

      mem t2 ["a";"c"]       >>= fun b2 ->
      assert_bool_equal "mem-ac" true b2;

      mem t2 ["a";"d"]       >>= fun b3  ->
      assert_bool_equal "mem-ad" true b3;
      read_exn t2 ["a";"d"]  >>= fun v1' ->
      assert_value_equal "v1" v1' v1;

      catch
        (fun () ->
           revert t2 r2      >>= fun () ->
           OUnit.assert_bool "revert" false;
           return_unit)
        (fun e ->
           import t2 full    >>= fun () ->
           revert t2 r2      >>= fun () ->
           mem t2 ["a";"d"]  >>= fun b4 ->
           assert_bool_equal "mem-ab" false b4;
           return_unit
        ) in
    run x test
*)
end

let suite (speed, x) =
  let (module S) = x.store in
  let module T = Make(S) in
  x.name,
  [
    "Basic operations on values"      , speed, T.test_values    x;
    "Basic operations on trees"       , speed, T.test_trees     x;
(*
    "Basic operations on revisions"   , speed, T.test_revisions x;
    "Basic operations on tags"        , speed, T.test_tags      x;
    "High-level store operations"     , speed, T.test_stores    x;
    "High-level store synchronisation", speed, T.test_sync      x;
*)
  ]

let run name tl =
  let tl = List.map suite tl in
  Alcotest.run name tl
