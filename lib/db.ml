open! Core
open! Async

module Photo = struct
  type t = { id : string; archive_path : string }
  [@@deriving sexp_of, fields, equal]

  let of_db_row row =
    match Array.to_list row with
    | [ id; archive_path ] -> Ok { id; archive_path }
    | _ ->
        Or_error.error_s
          [%message "Database error: failed to parse row" (row : string array)]
end

type t = Sqlite3.db

let or_error_of_rc rc =
  if Sqlite3.Rc.is_success rc then Ok ()
  else
    Or_error.error_string [%string "Sqlite3 error: %{Sqlite3.Rc.to_string rc}"]

let create_table_if_not_found t () =
  Sqlite3.exec t
    "CREATE TABLE IF NOT EXISTS photos (id string PRIMARY KEY, archive_path \
     string NOT NULL UNIQUE);"
  |> or_error_of_rc

let with_db ~db_file ~f =
  let t = Sqlite3.db_open ~mutex:`FULL db_file in
  let%map result =
    Monitor.try_with_join_or_error (fun () ->
        let%bind.Deferred.Or_error () =
          create_table_if_not_found t () |> return
        in
        f t)
  in
  match Sqlite3.db_close t with
  | false -> Or_error.error_s [%message "Failed to close sqlite3 database"]
  | true -> result

let insert_photo t photo =
  let { Photo.id; archive_path } = photo in
  Sqlite3.exec t
    [%string
      "INSERT INTO photos (id, archive_path) VALUES (%{id}, %{archive_path});"]
  |> or_error_of_rc

let lookup_photo t ~id =
  let results = ref [] in
  let%bind.Or_error () =
    Sqlite3.exec_not_null_no_headers t
      ~cb:(fun row -> results := !results @ [ row ])
      [%string "SELECT * FROM photos WHERE id = %{id} LIMIT 1"]
    |> or_error_of_rc
  in
  match !results with
  | [] -> Ok None
  | [ row ] ->
      let%map.Or_error photo = Photo.of_db_row row in
      Some photo
  | _ ->
      Or_error.error_s
        [%message "Database invariant violated: id not unique" (id : string)]

let all_photos t =
  let results = ref [] in
  let%bind.Or_error () =
    Sqlite3.exec_not_null_no_headers t
      ~cb:(fun row -> results := !results @ [ row ])
      [%string "SELECT * FROM photos"]
    |> or_error_of_rc
  in
  let%bind.Or_error photos_list =
    List.map !results ~f:Photo.of_db_row |> Or_error.combine_errors
  in
  List.map photos_list ~f:(fun photo -> (Photo.id photo, photo))
  |> String.Map.of_alist_or_error
