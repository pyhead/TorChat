{ TorChat - TSocketWrapper, thin wrapper around network sockets

  Copyright (C) 2012 Bernd Kreuss <prof7bit@gmail.com>

  This source is free software; you can redistribute it and/or modify it under
  the terms of the GNU General Public License as published by the Free
  Software Foundation; either version 3 of the License, or (at your option)
  any later version.

  This code is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
  details.

  A copy of the GNU General Public License is available on the World Wide Web
  at <http://www.gnu.org/copyleft/gpl.html>. You can also obtain it by writing
  to the Free Software Foundation, Inc., 59 Temple Place - Suite 330, Boston,
  MA 02111-1307, USA.
}
unit tc_sock;

{$mode objfpc}{$H+}

interface

uses
  Sockets,
{$ifdef windows}
  windows,
  WinSock2,
{$endif}
{$ifdef unix}
  errors,
{$endif}
  Classes,
  SysUtils,
  resolve,
  contnrs;

const
  Sys_EINPROGRESS = 115;
  Sys_EAGAIN = 11;
{$ifdef windows}
  SND_FLAGS = 0;
  RCV_FLAGS = 0;
{$else}
  SOCKET_ERROR = -1;
  SND_FLAGS = MSG_NOSIGNAL;
  RCV_FLAGS = MSG_NOSIGNAL;
{$endif}

type
  TSocketHandle = PtrInt;

  ENetworkError = class(Exception)
  end;

  TAsyncConnectThread = class;

  { TTCPStream wraps a TCP connection}
  TTCPStream = class(THandleStream)
  strict private
    FClosed: Boolean;
  public
    constructor Create(AHandle: TSocketHandle);
    destructor Destroy; override;
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    procedure DoClose; virtual;
    property Closed: Boolean read FClosed;
  end;

  PConnectionCallback = procedure(AStream: TTCPStream; E: Exception) of object;

  { TListenerThread }
  TListenerThread = class(TThread)
  strict private
    FStdOut           : Text;
    FPort             : DWord;
    FSocket           : TSocketHandle;
    FCallback         : PConnectionCallback;
  public
    constructor Create(APort: DWord; ACallback: PConnectionCallback); reintroduce;
    destructor Destroy; override;
    procedure Execute; override;
    procedure Terminate;
    property Port: DWord read FPort;
  end;

  { TSocketWrapper }
  TSocketWrapper = Class(TComponent)
  strict private
    FSocksProxyAddress  : String;
    FSocksProxyPort     : DWord;
    FSocksUser          : String;
    FIncomingCallback   : PConnectionCallback;
    FListeners          : TFPObjectList;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure StartListening(APort: DWord);
    procedure StopListening(APort: DWord);
    { this method will block, close HSocket to interrupt it! }
    function Connect(AServer: String; APort: DWord;
      out HSocket: TSocketHandle): TTCPStream;
    function ConnectAsync(AServer: String; APort: DWord;
      ACallback: PConnectionCallback): TAsyncConnectThread;
    property SocksProxyAddress: String write FSocksProxyAddress;
    property SocksProxyPort: DWord write FSocksProxyPort;
    property IncomingCallback: PConnectionCallback write FIncomingCallback;
  end;

  { TAsyncConnectThread }
  TAsyncConnectThread = class(TThread)
  strict private
    FStdOut: Text;
    FSocket: TSocketHandle;
    FSocketWrapper: TSocketWrapper;
    FCallback: PConnectionCallback;
    FServer: String;
    FPort: DWord;
  public
    constructor Create(ASocketWrapper: TSocketWrapper; AServer: String;
      APort: DWord; ACallback: PConnectionCallback);
    destructor Destroy; override;
    procedure Execute; override;
    { terminate the connect attempt }
    procedure Terminate;
  end;

implementation

function ErrorString(ACode: Integer): String;
var
  ErrStr: String;
  {$ifdef windows}
  ErrPtr: Pchar;
  {$endif}
begin
  {$ifdef windows}
  FormatMessage(
    FORMAT_MESSAGE_FROM_SYSTEM
    or FORMAT_MESSAGE_ALLOCATE_BUFFER
    or FORMAT_MESSAGE_IGNORE_INSERTS,
    nil,
    ACode,
    MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
    @ErrPtr,
    0,
    nil);
  if Assigned(ErrPtr) then begin
    ErrStr := Trim(ErrPtr);
    {$hints off}
    LocalFree(PtrInt(ErrPtr));
    {$hints on}
  end;
  {$else}
  ErrStr := StrError(ACode);
  {$endif}
  Result := Format('%d: %s', [ACode, ErrStr]);
end;

function LastErrorString: String;
begin
  Result := ErrorString(socketerror);
end;

function SWCreate: THandle;
begin
  Result := FPSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if Result <= 0 then
    raise ENetworkError.CreateFmt('could not create socket (%s)',
      [LastErrorString]);
  {$ifdef windows}
  // don't allow inheriting to child processes, otherwise we could not
  // close the listening sockets anymore once a child process is running
  SetHandleInformation(Result, 	HANDLE_FLAG_INHERIT, 0);
  {$endif}
end;

procedure SWClose(ASocket: THandle);
begin
  fpshutdown(ASocket, SHUT_RDWR);
  CloseSocket(ASocket);
end;

procedure SWBind(ASocket: THandle; APort: DWord);
var
  SockAddr  : TInetSockAddr;
begin
  SockAddr.sin_family := AF_INET;
  SockAddr.sin_port := ShortHostToNet(APort);
  SockAddr.sin_addr.s_addr := 0;

  if fpBind(ASocket, @SockAddr, SizeOf(SockAddr))<>0 then
    raise ENetworkError.CreateFmt('could not bind port %d (%s)',
      [APort, LastErrorString]);
end;

function SWResolve(AName: String): THostAddr;
var
  Resolver: THostResolver;
begin
  Result := StrToHostAddr(AName); // the string might be an IP address
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

procedure SWConnect(ASocket: THandle; AServer: String; APort: DWord);
var
  HostAddr: THostAddr;     // host byte order
  SockAddr: TInetSockAddr; // network byte order
  N: Integer;
begin
  HostAddr := SWResolve(AServer);
  SockAddr.sin_family := AF_INET;
  SockAddr.sin_port := ShortHostToNet(APort);
  SockAddr.sin_addr := HostToNet(HostAddr);
  N := FpConnect(ASocket, @SockAddr, SizeOf(SockAddr));
  if N <> 0 Then
    if (SocketError <> Sys_EINPROGRESS) and (SocketError <> 0) then begin
      SWClose(ASocket);
      raise ENetworkError.CreateFmt('connect failed: %s:%d (%s)',
        [AServer, APort, LastErrorString]);
    end;
end;


{ TAsyncConnectThread }

constructor TAsyncConnectThread.Create(ASocketWrapper: TSocketWrapper; AServer: String;
  APort: DWord; ACallback: PConnectionCallback);
begin
  FStdOut := Output;
  FSocketWrapper := ASocketWrapper;
  FCallback := ACallback;
  FServer := AServer;
  FPort := APort;
  FreeOnTerminate := True;
  Inherited Create(False);
end;

destructor TAsyncConnectThread.Destroy;
begin
  inherited Destroy;
end;

procedure TAsyncConnectThread.Execute;
var
  C : TTCPStream;
begin
  Output := FStdOut;
  try
    C := FSocketWrapper.Connect(FServer, FPort, FSocket);
    FCallback(C, nil);
  except
    on E: Exception do begin
      FCallback(nil, E);
    end;
  end;
end;

procedure TAsyncConnectThread.Terminate;
begin
  inherited Terminate;
  SWClose(FSocket);
end;


{ TSocketWrapper }

constructor TSocketWrapper.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FIncomingCallback := nil;
  FSocksUser := '';
  FSocksProxyAddress := '';
  FSocksProxyPort := 0;
  FListeners := TFPObjectList.Create(False);
end;

destructor TSocketWrapper.Destroy;
var
  I: Integer;
  Listener: TListenerThread;
begin
  WriteLn('TSocketWrapper.Destroy()');
  for I := FListeners.Count-1 downto 0 do begin
    Listener := FListeners.Items[I] as TListenerThread;
    Listener.Terminate;
    Listener.Free;
  end;
  FListeners.Free;
  inherited Destroy;
  WriteLn('TSocketWrapper.Destroy() finished');
end;

procedure TSocketWrapper.StartListening(APort: DWord);
var
  Listener: TListenerThread;
begin
  if FIncomingCallback = nil then
    raise ENetworkError.Create('No callback for incoming connections');
  Listener := TListenerThread.Create(APort, FIncomingCallback);
  FListeners.Add(Listener);
end;

procedure TSocketWrapper.StopListening(APort: DWord);
var
  I: Integer;
  L: TListenerThread;
begin
  for I := FListeners.Count-1 downto 0 do begin
    L := FListeners.Items[I] as TListenerThread;
    if L.Port = APort then begin
      FListeners.Remove(L);
      L.Terminate;
      L.Free;
      break;
    end;
  end;
end;

function TSocketWrapper.Connect(AServer: String; APort: DWord; out HSocket: TSocketHandle): TTCPStream;
var
  REQ : String;
  ANS : array[1..8] of Byte;
  N   : Integer;
begin
  HSocket := SWCreate;
  if (FSocksProxyAddress = '') or (FSocksProxyPort = 0) then begin
    SWConnect(HSocket, AServer, APort);
  end
  else begin
    SWConnect(HSocket, FSocksProxyAddress, FSocksProxyPort);
    SetLength(REQ, 8);
    REQ[1] := #4; // Socks 4
    REQ[2] := #1; // CONNECT command
    PWord(@REQ[3])^ := ShortHostToNet(APort);
    PDWord(@REQ[5])^ := HostToNet(1); // address '0.0.0.1' means: Socks 4a
    REQ := REQ + FSocksUser + #0;
    REQ := REQ + AServer + #0;
    fpSend(HSocket, @REQ[1], Length(REQ), SND_FLAGS);
    ANS[1] := $ff;
    N := fpRecv(HSocket, @ANS, 8, RCV_FLAGS);
    if (N <> 8) or (ANS[1] <> 0) then begin
      SWClose(HSocket);
      Raise ENetworkError.CreateFmt(
        'socks connect %s:%d via %s:%d handshake invalid response',
        [AServer, APort, FSocksProxyAddress, FSocksProxyPort]
      );
    end;
    if ANS[2] <> 90 then begin
      SWClose(HSocket);
      Raise ENetworkError.CreateFmt(
        'socks connect %s:%d via %s:%d failed (error %d)',
        [AServer, APort, FSocksProxyAddress, FSocksProxyPort, ANS[2]]
      );
    end;
  end;
  Result := TTCPStream.Create(HSocket);
end;

function TSocketWrapper.ConnectAsync(AServer: String; APort: DWord;
  ACallback: PConnectionCallback): TAsyncConnectThread;
begin
  Result := TAsyncConnectThread.Create(Self, AServer, APort, ACallback);
end;

{ TListenerThread }

constructor TListenerThread.Create(APort: DWord; ACallback: PConnectionCallback);
begin
  FPort := APort;
  FCallback := ACallback;
  FStdOut := Output;
  FSocket := SWCreate;
  SWBind(FSocket, FPort);
  fplisten(FSocket, 1);
  Inherited Create(false);
end;

destructor TListenerThread.Destroy;
begin
  inherited Destroy;
end;

procedure TListenerThread.Execute;
var
  SockAddr  : TInetSockAddr;
  AddrLen   : PtrUInt;
  Incoming  : PtrInt;
  Err       : Integer;
begin
  Output := FStdOut;
  AddrLen := SizeOf(SockAddr);

  while not Terminated do begin;
    Incoming := fpaccept(FSocket, @SockAddr, @AddrLen);
    Err := socketerror;
    if Err = 0 then
      FCallback(TTCPStream.Create(Incoming), nil)
    else begin
      WriteLn('I TListenerThread.Execute(): ', ErrorString(Err));
      break;
    end;
  end;
end;

procedure TListenerThread.Terminate;
begin
  inherited Terminate;
  SWClose(FSocket);
end;

{ TTCPStream }

constructor TTCPStream.Create(AHandle: TSocketHandle);
begin
  inherited Create(AHandle);
  FClosed := False;
end;

destructor TTCPStream.Destroy;
begin
  DoClose;
  inherited Destroy;
end;

function TTCPStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  Result := fpSend(Handle, @Buffer, Count, SND_FLAGS);
end;

function TTCPStream.Read(var Buffer; Count: LongInt): LongInt;
begin
  Result := fpRecv(Handle, @Buffer, Count, RCV_FLAGS);
  if Result = SOCKET_ERROR then
    DoClose;
end;

procedure TTCPStream.DoClose;
begin
  if not FClosed then begin
    SWClose(Handle);
    FClosed := True;
  end;
end;

end.

