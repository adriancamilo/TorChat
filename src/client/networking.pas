unit networking;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Sockets, resolve, errors;

const
  Sys_EINPROGRESS = 115;
  Sys_EAGAIN = 11;

type
  ENetworkError = class(Exception)
  end;

  { TConnection wraps a socket}
  TConnection = class(THandleStream)
    constructor Create(AHandle: THandle); reintroduce;
    destructor Destroy; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    procedure WriteLn(S: String); virtual;
    procedure DoClose; virtual;
  strict protected
    FClosed: Boolean;
    procedure SetClosed; virtual;
  public
    property Closed: Boolean read FClosed;
  end;

  { TReceiver }
  TReceiver = class (TThread)
    constructor Create(AConnection: TConnection);
    procedure Execute; override;
  strict protected
    FConn: TConnection;
  end deprecated 'This class will be removed, its only for testing, client will need its own receiver thread';

  TListenerCallback = procedure(AConnection: TConnection) of object;

  { TListener }
  TListener = class(TThread)
    constructor Create(APort: DWord; ACallback: TListenerCallback); reintroduce;
    procedure Execute; override;
    procedure Terminate;
  strict protected
    FPort     : DWord;
    FSocket   : THandle;
    FCallback : TListenerCallback;
  end;

function ConnectTCP(AServer: String; APort: DWord): TConnection;
function ConnectSocks4a(AProxy: String; AProxyPort: DWord; AServer: String; APort: DWord): TConnection;
function NameResolve(AName: String): THostAddr;

implementation

function CreateSocketHandle: THandle;
begin
  Result := Sockets.FPSocket(AF_INET, SOCK_STREAM, 0);
  if Result = -1 then
    raise ENetworkError.CreateFmt('could not create socket (%s)',
      [StrError(SocketError)]);
end;

procedure CloseSocketHandle(ASocket: THandle);
begin
  fpshutdown(ASocket, SHUT_RDWR);
  Sockets.CloseSocket(ASocket);
end;

{ TListener }

constructor TListener.Create(APort: DWord; ACallback: TListenerCallback);
begin
  FPort := APort;
  FCallback := ACallback;
  Inherited Create(false);
end;

procedure TListener.Execute;
var
  TrueValue : Integer;
  SockAddr  : TInetSockAddr;
  SockAddrx : TInetSockAddr;
  AddrLen   : PtrInt;
  Incoming  : THandle;
begin
  TrueValue := 1;
  AddrLen := SizeOf(SockAddr);

  FSocket := CreateSocketHandle;
  fpSetSockOpt(FSocket, SOL_SOCKET, SO_REUSEADDR, @TrueValue, SizeOf(TrueValue));
  SockAddr.sin_family := AF_INET;
  SockAddr.sin_port := ShortHostToNet(FPort);
  SockAddr.sin_addr.s_addr := 0;

  if fpBind(FSocket, @SockAddr, SizeOf(SockAddr))<>0 then
    raise ENetworkError.CreateFmt('could not bind port %d (%s)',
      [FPort, StrError(SocketError)]);

  fpListen(FSocket, 1);
  repeat
    Incoming := fpaccept(FSocket, @SockAddrx, @AddrLen);
    if Incoming <> -1 then
      FCallback(TConnection.Create(Incoming))
    else
      break;
  until Terminated;
end;

procedure TListener.Terminate;
begin
  CloseSocketHandle(Self.FSocket);
  inherited Terminate;
end;

{ TReceiver }

constructor TReceiver.Create(AConnection: TConnection);
begin
  FConn := AConnection;
  inherited Create(False);
end;

procedure TReceiver.Execute;
var
  B : array[0..1024] of Char = #0;
  N : Integer;
begin
  repeat
    N := FConn.Read(B, 1024);
    B[N] := #0;
    write(PChar(@B[0]));
  until (N = 0) or Terminated;
end;

{ TConnection }

constructor TConnection.Create(AHandle: THandle);
begin
  inherited Create(AHandle);
end;

destructor TConnection.Destroy;
begin
  DoClose;
  inherited Destroy;
end;

function TConnection.Write(const Buffer; Count: LongInt): LongInt;
begin
  Result := FPsend(Handle, @Buffer, Count, MSG_NOSIGNAL);
end;

function TConnection.Read(var Buffer; Count: LongInt): LongInt;
begin
  Result := fprecv(Handle, @Buffer, Count, MSG_NOSIGNAL);
  if Result = -1 then
    DoClose;
end;

procedure TConnection.WriteLn(S: String);
var
  Buf: String;
begin
  Buf := S + #10; // LF is the TorChat message delimiter (on all platforms!)
  self.Write(Buf[1], Length(Buf));
end;

procedure TConnection.DoClose;
begin
  if not Closed then begin
    CloseSocketHandle(Handle);
    SetClosed;
  end;
end;

procedure TConnection.SetClosed;
begin
  FClosed := True;
end;


function ConnectTCP(AServer: String; APort: DWord): TConnection;
var
  HostAddr: THostAddr;     // host byte order
  SockAddr: TInetSockAddr; // network byte order
  HSocket: THandle;
begin
  HostAddr := NameResolve(AServer);
  SockAddr.sin_family := AF_INET;
  SockAddr.sin_port := ShortHostToNet(APort);
  SockAddr.sin_addr := HostToNet(HostAddr);
  HSocket := CreateSocketHandle;
  if Sockets.FpConnect(HSocket, @SockAddr, SizeOf(SockAddr))<>0 Then
    if (SocketError <> Sys_EINPROGRESS) and (SocketError <> 0) then
      raise ENetworkError.CreateFmt('connect failed: %s:%d (%s)',
        [AServer, APort, StrError(SocketError)]);
  Result := TConnection.Create(HSocket);
end;

function ConnectSocks4a(AProxy: String; AProxyPort: DWord; AServer: String; APort: DWord): TConnection;
var
  C : TConnection;
begin
  C := ConnectTCP(AProxy, AProxyPort);
  Result := C;
end;

function NameResolve(AName: String): THostAddr;
var
  Resolver: THostResolver;
begin
  Result := StrToHostAddr(AName);
  if Result.s_addr = 0 then begin
    try
      Resolver := THostResolver.Create(nil);
      if not Resolver.NameLookup(AName) then
        raise ENetworkError.CreateFmt('could not resolve address: %s', [AName]);
      Result := Resolver.HostAddress;
    finally
      Resolver.Free;
    end;
  end;
end;

end.
