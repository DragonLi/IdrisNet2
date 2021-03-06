module Main
import Effects
import Effect.StdIO
import IdrisNet.Socket
import IdrisNet.UDP.UDPServer

udpServerLoop : Nat -> 
                { [UDPSERVER UDPBound, STDIO] ==> 
                  [UDPSERVER (), STDIO] }
                Eff IO ()
udpServerLoop Z = udpClose
udpServerLoop (S k) = do
  case !(udpReadString 1024) of
    UDPSuccess (addr, str, _) => do
      putStr ("Received: " ++ str ++ "from " ++ (show (remote_addr addr)) ++ "\n")
      UDPSuccess _ <- udpWriteString (IPv4Addr 127 0 0 1) 9001 "pines test"
        | UDPFailure err => do putStr ("Error!" ++ (show err))
                               udpFinalise
        | UDPRecoverableError err => do putStr ("Error!" ++ (show err))
                                        udpClose
      udpServerLoop k
    UDPRecoverableError _ => udpServerLoop (S k)
    UDPFailure err => do
      putStr ("Error: " ++ (show err) ++ "\n")
      udpFinalise

udpBindAndLoop : Port ->
                 { [UDPSERVER (), STDIO] }
                 Eff IO ()
udpBindAndLoop p = do
  case !(udpBind Nothing p) of
    UDPSuccess _ => udpServerLoop 5
    UDPRecoverableError err => putStr ("Error binding: " ++ (show err) ++ "\n")
    UDPFailure err => putStr ("Error binding: " ++ (show err) ++ "\n")


main : IO ()
main = run (udpBindAndLoop 4099)
