# 네트워크 (Win32.h · UDP · TCP)

목차: 1. Win32.h · 2. UdpSocket · 3. TCP

## 1. Win32.h — Win32 헤더는 이 파일 하나만 include

```cpp
// Win32.h
#pragma once
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>   // windows.h보다 먼저
#include <ws2tcpip.h>
#include <mstcpip.h>
#include <windows.h>
#include <mmsystem.h>   // timeSetEvent 등 (Winmm.lib)

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif
```

## 2. UdpSocket (UdpClient 대응)

- 프로세스 시작 시 `WinsockInit` 객체 하나를 `main`에 둔다.
- 수신은 전용 스레드에서 `recvfrom` 반복. 종료는 `closesocket`으로 깨운 뒤 `join`.
- 수신 콜백은 수신 스레드에서 돈다. 원본처럼 큐(`ActionQueueThread::Post`)로 넘긴다.
- `SO_REUSEADDR`는 **원본이 `SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true)`를 쓸 때만** 켠다(`Open`의 인자). `ExclusiveAddressUse = false`는 기본값일 뿐 재사용을 켜지 않는다.
- 원본이 수신 스레드에서 동기 `UdpClient.Receive(ref ep)`를 부르면 그 스레드 구조를 그대로 두고 `Receive()`를 쓴다. `StartReceive`는 원본이 비동기 수신(`BeginReceive` 등)일 때만.
- 원본이 `SIO_UDP_CONNRESET`을 끄면 `DisableConnReset()`을 호출한다.
- `WSAECONNRESET` 말고 다른 수신 오류가 나면 루프를 끝낸다. 원본이 재개방하면 그 동작을 옮기고, 불명확하면 `TODO(PORT)`.

```cpp
// UdpSocket.h
#pragma once
#include <atomic>
#include <cstdint>
#include <functional>
#include <span>
#include <string>
#include <thread>
#include <vector>
#include "TerminateLogger.h"
#include "Win32.h"

#pragma comment(lib, "Ws2_32.lib")

class WinsockInit {
public:
    WinsockInit() { mOk = (WSAStartup(MAKEWORD(2, 2), &mData) == 0); }
    ~WinsockInit() {
        if (mOk) {
            WSACleanup();
        }
    }
    bool Ok() const { return mOk; }
    WinsockInit(const WinsockInit&) = delete;
    WinsockInit& operator=(const WinsockInit&) = delete;

private:
    WSADATA mData{};
    bool mOk = false;
};

// C#: UdpClient. 수신 콜백 인자는 (데이터, 송신자 IP, 송신자 포트). 데이터는 콜백 안에서만 유효하다
class UdpSocket {
public:
    using RecvHandler = std::function<void(std::span<const uint8_t>, const std::string&, uint16_t)>;

    UdpSocket() = default;
    ~UdpSocket() { Close(); }
    UdpSocket(const UdpSocket&) = delete;
    UdpSocket& operator=(const UdpSocket&) = delete;

    // localIp가 빈 문자열이면 INADDR_ANY. reuseAddress는 원본이 켤 때만 true.
    bool Open(const std::string& localIp, uint16_t localPort, bool reuseAddress = false) {
        if (mSocket != INVALID_SOCKET) {
            return false;
        }
        SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (s == INVALID_SOCKET) {
            return false;
        }
        if (reuseAddress) {
            BOOL on = TRUE;
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&on), sizeof(on));
        }
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(localPort);
        if (localIp.empty()) {
            addr.sin_addr.s_addr = htonl(INADDR_ANY);
        } else if (inet_pton(AF_INET, localIp.c_str(), &addr.sin_addr) != 1) {
            closesocket(s);
            return false;
        }
        if (bind(s, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) == SOCKET_ERROR) {
            closesocket(s);
            return false;
        }
        mSocket = s;
        return true;
    }

    // C#: client.Client.IOControl(SIO_UDP_CONNRESET, false) — ICMP 포트 도달 불가로 recvfrom이 실패하지 않게 한다.
    bool DisableConnReset() {
        BOOL newBehavior = FALSE;
        DWORD bytes = 0;
        return WSAIoctl(mSocket, SIO_UDP_CONNRESET, &newBehavior, sizeof(newBehavior), nullptr, 0, &bytes, nullptr, nullptr) == 0;
    }

    // C#: JoinMulticastGroup(groupIp, localIp)
    bool JoinMulticastGroup(const std::string& groupIp, const std::string& localIfIp) {
        ip_mreq mreq{};
        if (inet_pton(AF_INET, groupIp.c_str(), &mreq.imr_multiaddr) != 1) {
            return false;
        }
        if (localIfIp.empty()) {
            mreq.imr_interface.s_addr = htonl(INADDR_ANY);
        } else if (inet_pton(AF_INET, localIfIp.c_str(), &mreq.imr_interface) != 1) {
            return false;
        }
        return setsockopt(mSocket, IPPROTO_IP, IP_ADD_MEMBERSHIP,
                          reinterpret_cast<const char*>(&mreq), sizeof(mreq)) != SOCKET_ERROR;
    }

    // C#: EnableBroadcast = true (예: WOL 브로드캐스트)
    bool EnableBroadcast() {
        BOOL on = TRUE;
        return setsockopt(mSocket, SOL_SOCKET, SO_BROADCAST, reinterpret_cast<const char*>(&on), sizeof(on)) != SOCKET_ERROR;
    }

    // C#: Send(bytes, length, endPoint). 보낸 바이트 수, 실패 시 -1
    int SendTo(std::span<const uint8_t> data, const std::string& destIp, uint16_t destPort) {
        sockaddr_in dest{};
        dest.sin_family = AF_INET;
        dest.sin_port = htons(destPort);
        if (inet_pton(AF_INET, destIp.c_str(), &dest.sin_addr) != 1) {
            return -1;
        }
        const int r = sendto(mSocket, reinterpret_cast<const char*>(data.data()), static_cast<int>(data.size()), 0,
                             reinterpret_cast<const sockaddr*>(&dest), sizeof(dest));
        return (r == SOCKET_ERROR) ? -1 : r;
    }

    // C#: Receive(ref remoteEP). 받은 바이트 수, 실패 시 -1 (소켓이 닫히면 -1).
    int Receive(std::vector<uint8_t>& out, std::string& fromIp, uint16_t& fromPort) {
        out.resize(65536);
        sockaddr_in from{};
        int fromLen = sizeof(from);
        const int n = recvfrom(mSocket, reinterpret_cast<char*>(out.data()), static_cast<int>(out.size()), 0,
                               reinterpret_cast<sockaddr*>(&from), &fromLen);
        if (n == SOCKET_ERROR) {
            out.clear();
            return -1;
        }
        out.resize(static_cast<size_t>(n));
        char ip[INET_ADDRSTRLEN] = {};
        inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
        fromIp = ip;
        fromPort = ntohs(from.sin_port);
        return n;
    }

    // 수신 스레드를 시작한다. 열지 않았거나 이미 시작했으면 false.
    bool StartReceive(RecvHandler handler) {
        if (mSocket == INVALID_SOCKET || mThread.joinable()) {
            return false;
        }
        mHandler = std::move(handler);
        mRunning = true;
        mThread = std::jthread([this, s = mSocket] { RunThreadBody([this, s] { ReceiveLoop(s); }); });
        return true;
    }

    void Close() {
        mRunning = false;
        if (mSocket != INVALID_SOCKET) {
            closesocket(mSocket);   // recvfrom을 깨운다
        }
        if (mThread.joinable() && mThread.get_id() != std::this_thread::get_id()) {
            mThread.join();
        }
        mSocket = INVALID_SOCKET;
    }

private:
    // 소켓 값은 인자로 받는다 (Close가 멤버를 바꾸는 것과 경합하지 않게).
    void ReceiveLoop(SOCKET s) {
        std::vector<uint8_t> buf(65536);
        while (mRunning) {
            sockaddr_in from{};
            int fromLen = sizeof(from);
            const int n = recvfrom(s, reinterpret_cast<char*>(buf.data()), static_cast<int>(buf.size()), 0,
                                   reinterpret_cast<sockaddr*>(&from), &fromLen);
            if (n == SOCKET_ERROR) {
                if (!mRunning) {
                    break;   // Close()로 깨어남
                }
                if (WSAGetLastError() == WSAECONNRESET) {
                    continue;   // 원본이 무시하면 그대로. 원본 처리가 다르면 옮긴다
                }
                break;   // TODO(PORT): 원본의 수신 오류 처리(재개방 등) 확인
            }
            char ip[INET_ADDRSTRLEN] = {};
            inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
            if (mHandler) {
                mHandler(std::span<const uint8_t>(buf.data(), static_cast<size_t>(n)), ip, ntohs(from.sin_port));
            }
        }
    }

    SOCKET mSocket = INVALID_SOCKET;
    std::atomic<bool> mRunning{false};
    RecvHandler mHandler;
    std::jthread mThread;
};
```

수신 콜백에서 난 예외는 원본 수신 루프의 `catch`와 같게 처리한다. 원본에 `catch`가 없으면 그대로 두고 보고에 적는다(SKILL.md 규칙 16).

## 3. TCP (TcpClient 대응)

틀은 Winsock TCP(`socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)`, `connect`, `recv` 루프)다. 프레이밍(길이 필드 위치, 헤더 크기)·재연결 정책·바이트 순서는 C# 원본을 따른다.

TCP는 `recv` 한 번이 메시지 하나와 맞지 않는다. 누적 버퍼에 쌓다가 헤더의 길이만큼 모이면 꺼낸다. 원본이 `NetworkStream.Read`를 한 번만 부르고 메시지 하나로 가정하면, 그대로 옮기고 `TODO(PORT-BUG?)`로 표시한다.
