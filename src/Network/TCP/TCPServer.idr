module Network.TCP.TCPServer
import Effects
import Network.Socket
import Network.TCP.TCPCommon

-- Closed -> Listening

-- Alright, so for a basic server, we just want a Client pointer
-- and send to / receive from that.

-- A multithreaded server would be a bit smarter (although we're still
-- forking as opposed to doing Actual Threading at the moment...)


data ServerBound : Type where
  SB : Socket -> ServerBound

data ServerListening : Type where 
  SL : Socket -> ServerListening

data ServerError : Type where
  SE : Socket -> ServerError

data ClientConnected : Type where
  CC : Socket -> SocketAddress -> ClientConnected

data ClientError : Type where
  CE : Socket -> ClientError

interpOperationRes : SocketOperationRes a -> Type
interpOperationRes (OperationSuccess _) = ServerListening
interpOperationRes (FatalError _) = ServerError
interpOperationRes (RecoverableError _) = ServerListening
interpOperationRes (ConnectionClosed) = ()

interpClientOperationRes : SocketOperationRes a -> Type
interpClientOperationRes (OperationSuccess _) = ClientConnected
interpClientOperationRes (FatalError _) = ClientError
interpClientOperationRes (RecoverableError _) = ClientConnected
interpClientOperationRes (ConnectionClosed) = ()

interpListenRes : SocketOperationRes a -> Type
interpListenRes (OperationSuccess _) = ServerListening
interpListenRes ConnectionClosed = ()
interpListenRes (RecoverableError _) = ServerBound
interpListenRes (FatalError _) = ServerError

interpBindRes : SocketOperationRes a -> Type
interpBindRes (OperationSuccess _) = ServerBound
interpBindRes _ = ()

{- This is an effect that deals with an accepted client. We're allowed to 
   read from, write to, and close this socket. 
   An effectual program of type TCPSERVERCLIENT will be run, initially in the
   ClientConnected state, upon acceptance of a client. This will be given in the
   form of an argument to Accept. The effectual program must end by closing the socket. -}
data TCPServerClient : Effect where
  WriteString : String -> TCPServerClient (SocketOperationRes ByteLength)
                                          (ClientConnected) 
                                          (interpClientOperationRes)
  ReadString : ByteLength -> TCPServerClient (SocketOperationRes (String, ByteLength))
                                             (ClientConnected)
                                             (interpClientOperationRes)
  CloseClient : TCPServerClient () (ClientConnected) (const ())
  FinaliseClient : TCPServerClient () (ClientError) (const ())

TCPSERVERCLIENT : Type -> EFFECT 
TCPSERVERCLIENT t = MkEff t TCPServerClient


tcpSend : String -> { [TCPSERVERCLIENT (ClientConnected)] ==> 
                      [TCPSERVERCLIENT (interpClientOperationRes result)] }
                    EffM IO (SocketOperationRes ByteLength)
tcpSend s = (WriteString s)

tcpRecv : ByteLength -> { [TCPSERVERCLIENT (ClientConnected)] ==> 
                          [TCPSERVERCLIENT (interpClientOperationRes result)] }
                        EffM IO (SocketOperationRes (String, ByteLength))
tcpRecv bl = (ReadString bl)

closeClient : { [TCPSERVERCLIENT (ClientConnected)] ==> [TCPSERVERCLIENT ()] } EffM IO ()
closeClient = CloseClient

finaliseClient : { [TCPSERVERCLIENT (ClientError)] ==> [TCPSERVERCLIENT ()] } EffM IO ()
finaliseClient = FinaliseClient

ClientProgram : Type -> Type
ClientProgram t = {[TCPSERVERCLIENT (ClientConnected)] ==> [TCPSERVERCLIENT ()]} EffM IO t

instance Handler TCPServerClient IO where
  handle (CC sock addr) (WriteString str) k = do
    send_res <- send sock str
    case send_res of 
      Left err => 
        if (err == EAGAIN) then
          k (RecoverableError err) (CC sock addr)
        else
          k (FatalError err) (CE sock) 
      Right bl => k (OperationSuccess bl) (CC sock addr) 

  handle (CC sock addr) (ReadString bl) k = do
    recv_res <- recv sock bl
    case recv_res of
      Left err =>
        if err == EAGAIN then
          k (RecoverableError err) (CC sock addr)  
        else if err == 0 then -- Socket closed
          k (ConnectionClosed) ()
        else k (FatalError err) (CE sock)
      Right (str, bl) => k (OperationSuccess (str, bl)) (CC sock addr)

  handle (CC sock addr) (CloseClient) k = 
    close sock $> k () ()
  handle (CE sock) (FinaliseClient) k = 
    close sock $> k () ()

data TCPServer : Effect where
  -- Bind a socket to a given address and port
  Bind : SocketAddress -> Port -> TCPServer (SocketOperationRes ()) 
                                            () (interpBindRes)
  -- Listen
  Listen : TCPServer (SocketOperationRes ()) (ServerBound) (interpListenRes)
{-
  -- Write to a client socket
  WriteString : Socket -> String -> TCPServer (SocketOperationRes ByteLength) 
                                      (ServerListening) (interpOperationRes)
  -- Read from a client socket
  ReadString : Socket -> ByteLength -> TCPServer (SocketOperationRes ByteLength)
                                        (ServerListening) (interpOperationRes)
                                        -}
  Accept :  ClientProgram t ->
            TCPServer (SocketOperationRes t)
                      (ServerListening) (interpOperationRes)

  -- Need separate ones for each. It'd be nice to condense these into 1...
  CloseBound : TCPServer () (ServerBound) (const ())
  CloseListening : TCPServer () (ServerListening) (const ())
  Finalise : TCPServer () (ServerError) (const ())
  

TCPSERVER : Type -> EFFECT
TCPSERVER t = MkEff t TCPServer

{- TCP Accessor Functions -}

bind : SocketAddress -> Port -> { [TCPSERVER ()] ==> [TCPSERVER (interpBindRes result)] } 
                                EffM IO (SocketOperationRes ())
bind sa p = (Bind sa p)

listen : { [TCPSERVER (ServerBound)] ==> [TCPSERVER (interpListenRes result)] } 
         EffM IO (SocketOperationRes ())
listen = Listen

accept : ClientProgram t -> 
         { [TCPSERVER (ServerListening)] ==> [TCPSERVER (interpOperationRes result)] }
         EffM IO (SocketOperationRes t)
accept prog = (Accept prog)

closeBound : { [TCPSERVER (ServerBound)] ==> [TCPSERVER ()] } EffM IO ()
closeBound = CloseBound

closeListening : { [TCPSERVER (ServerListening)] ==> [TCPSERVER ()] } EffM IO ()
closeListening = CloseListening

finaliseServer : { [TCPSERVER (ServerError)] ==> [TCPSERVER ()] } EffM IO ()
finaliseServer = Finalise

{- Handler Functions -}
instance Handler TCPServer IO where 
  handle () (Bind sa p) k = do
    sock_res <- socket AF_INET Stream 0
    case sock_res of
      Left err => k (FatalError err) ()
      Right sock => do
        bind_res <- bind sock sa p
        if bind_res == 0 then
          -- Binding succeeded \o/
          k (OperationSuccess ()) (SB sock)
        else do
          close sock
          k (FatalError bind_res) ()
          
  handle (SB sock) (Listen) k = do
    listen_res <- listen sock
    if listen_res == 0 then
      -- Success
      k (OperationSuccess ()) (SL sock)
    else
      k (FatalError listen_res) (SE sock)

  handle (SL sock) (Accept prog) k = do
    accept_res <- accept sock
    case accept_res of
         Left err => do
           if err == EAGAIN then 
             k (RecoverableError err) (SL sock)
           else 
             k (FatalError err) (SE sock) 
         Right (client_sock, addr) => do
           res <- run [(CC client_sock addr)] prog
           k (OperationSuccess res) (SL sock)  

  handle (SB sock) (CloseBound) k = 
    close sock $> k () ()

  handle (SL sock) (CloseListening) k = 
    close sock $> k () ()

  handle (SE sock) (Finalise) k = 
    close sock $> k () ()


