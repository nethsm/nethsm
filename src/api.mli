module Dispatch (H:Cohttp_lwt.S.Server)(KR:Keyring.S)(Clock:Webmachine.CLOCK) : sig
  val dispatcher : KR.storage -> Cohttp.Request.t -> Cohttp_lwt.Body.t
    -> (Cohttp.Response.t * Cohttp_lwt.Body.t) Lwt.t
end
