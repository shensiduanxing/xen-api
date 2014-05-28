(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Xstringext
open Opt

type pci_property = {
	id: int64;
	name: string;
}

type pci = {
	pci_id: string;
	vendor: pci_property;
	device: pci_property;
	pci_class: pci_property;
	related: string list;
}

let wrap_lookup f id =
	try f id
	with Not_found -> Printf.sprintf "Unknown (%04Lx)" id

let parse_lspci_line pci_db line =
	let fields = String.split ' ' line in
	let fields = List.filter (fun s -> not (String.startswith "-" s)) fields in
	Scanf.sscanf (String.concat " " fields) "%s \"%s@\" \"%Lx@\" \"%Lx@\""
		(fun pci_id class_subclass vendor_id device_id ->
			let int_of_hex_str = fun s -> Scanf.sscanf s "%Lx" (fun x -> x) in
			let class_id = int_of_hex_str (String.sub class_subclass 0 2) in
			let open Pci_db in
			let vendor_name = wrap_lookup (fun vendor_id ->
				(Pci_db.get_vendor pci_db vendor_id).v_name) vendor_id in
			let device_name = wrap_lookup (fun device_id ->
				(Pci_db.get_device pci_db vendor_id device_id).d_name) device_id in
			let class_name = (Pci_db.get_class pci_db class_id).c_name in
			(* we'll fill in the related field when we've finished parsing *)
			let related = [] in
			{
				pci_id;
				vendor = {id = vendor_id; name = vendor_name};
				device = {id = device_id; name = device_name};
				pci_class = {id = class_id; name = class_name};
				related
			})

let find_related_ids pci other_pcis =
	let slot id = String.sub id 0 (String.index id '.') in
	List.map
		(fun p -> p.pci_id)
		(List.filter
			(fun p -> p.pci_id <> pci.pci_id && slot p.pci_id = slot pci.pci_id) other_pcis)

let get_host_pcis pci_db =
	let lspci_path =
		(* TODO: switch to using $PATH like normal people *)
		if Sys.file_exists "/sbin/lspci"
		then "/sbin/lspci"
		else if Sys.file_exists "/usr/bin/lspci"
		then "/usr/bin/lspci"
		else "lspci" in
	let lspci_out, _ = Forkhelpers.execute_command_get_output lspci_path ["-mnD"] in
	let lspci_lines = String.split '\n' lspci_out in

	let rec parse_lspci_lines pci_db ac = function
		| [] -> ac
		| hd :: tl ->
			try
				let pci = parse_lspci_line pci_db hd in
				parse_lspci_lines pci_db (pci :: ac) tl
			with _ -> parse_lspci_lines pci_db ac tl
	in
	let pcis = parse_lspci_lines pci_db [] lspci_lines in
	let rec link_related_pcis ac = function
		| [] -> ac
		| hd :: tl ->
			let related = find_related_ids hd pcis in
			let pci = {hd with related} in
			link_related_pcis (pci :: ac) tl
	in
	link_related_pcis [] pcis
