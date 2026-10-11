## Running the Server

To run the example server in production mode, use the following command:

```sh
v -prod run examples/etag/src
```

### Serving the Front-End

To serve the front-end files, execute:

```sh
v -e 'import net.http.file; file.serve(folder: "examples/etag/front-end")'
```

Then open <http://localhost:4001/> and click the button twice: the first click
gets a `200` with the ETag, the second sends it back in `If-None-Match` and gets
`304 Not Modified`. The page is a different origin than the API (`:4001` vs
`:3000`), so the server answers the CORS preflight and exposes the `ETag` header.

### Testing with ETag

You can test the server's ETag functionality using `curl`:

1. Fetch a resource and note its `ETag` (a quoted 64-bit wyhash of the body):

   ```sh
   curl -v http://localhost:3000/user/1
   # < ETag: "21c9de031ab7e66c"
   ```

2. Send that ETag back, quotes included, and get `304 Not Modified`:
   ```sh
   curl -v -H 'If-None-Match: "21c9de031ab7e66c"' http://localhost:3000/user/1
   ```

The comparison is an exact match on the quoted value: weak (`W/"…"`), list and
`*` forms are not supported by this example.

## Benchmarking

### Benchmarking with `wrk`

You can benchmark the server's performance using `wrk`. For example:

```sh
wrk -t16 -c512 -d30s http://localhost:3000/user/1
```

### Benchmarking with ETag Header

To benchmark the `304` path, send the ETag from the curl step above:

```sh
wrk -t16 -c512 -d30s -H 'If-None-Match: "21c9de031ab7e66c"' http://localhost:3000/user/1
```
