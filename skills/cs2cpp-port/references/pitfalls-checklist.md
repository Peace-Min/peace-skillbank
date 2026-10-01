# 자가 점검표

**해당하는 항목만** 근거(함수명·줄)와 함께 `확인` 또는 `문제: …`로 적는다. 해당하지 않는 항목은 번호만 모아 `해당 없음: A3, C5, …`로 한 줄에 적는다.

## A. 환경

- A1 C++20 기능을 쓰지 않았다 (`contains`, `starts_with`, `std::format`, `std::span`, 지정 초기화 등)
- A2 표준 라이브러리·Win32 외 라이브러리를 쓰지 않았다
- A3 `using namespace std;`가 없다
- A4 Win32 헤더는 `Win32.h`로만 include했다
- A5 헤더에 `#pragma once`, 포인터·참조로만 쓰는 형식은 전방 선언
- A6 공용 패턴 헤더를 새로 만들지 않고 기존 것을 include했다

## B. 동작 보존

- B1 클래스·메서드·필드 이름이 C#과 같다
- B2 추적 주석이 있다 (줄 번호는 입력에 있을 때만)
- B3 분기·반복·호출 순서를 빠뜨리거나 합치지 않았다
- B4 버그 의심은 고치지 않고 `TODO(PORT-BUG?)`로 표시했다
- B5 포팅된 의존 형식은 헤더·`API_MAP.md`의 선언대로 호출했다
- B6 로그 호출의 위치·레벨·문구를 옮겼다

## C. 타입·수치·문자열

- C1 `long`/`unsigned long`을 쓰지 않았다
- C2 모든 멤버 필드에 초기값이 있다
- C3 문자열에 숫자·bool·enum을 `+`로 잇지 않았다 (`StrFormat`)
- C4 `int`와 `uint` 섞인 비교·연산을 `int64_t`로 맞췄다
- C5 축소 변환에 `static_cast`가 있다
- C6 부호 있는 overflow, 시프트 수 초과, 음수 왼쪽 시프트를 처리했다
- C7 `Math.Round`·`Convert.ToInt32(double)`·`int.Parse`를 `NetCompat`로 옮겼다
- C8 인덱서 읽기를 `DictAt`/`ListAt`/`ArrayAt`로 옮겼다
- C9 `Dictionary` 순회 순서 의존 여부를 확인했다
- C10 문자열 길이로 분기하는 곳에 한글이 들어갈 수 있는지 확인했다
- C11 `switch`의 모든 `case`에 `break`가 있다

## D. 객체·수명

- D1 `new`/`delete`를 직접 쓰지 않았다
- D2 C# 참조형(class·배열·`List`·`Dictionary`)을 값 복사로 바꾸지 않았다
- D3 비소유 포인터·참조가 가리키는 객체가 더 오래 산다
- D4 class `==`는 포인터 비교, 재정의된 `==`는 값 비교로 옮겼다
- D5 상속 클래스에 가상 소멸자, 재정의에 `override`
- D6 생성자에서 가상 함수를 부르지 않는다
- D7 속성 복합 연산(`++`, `+=`)을 Get/Set으로 풀었다
- D8 스레드·소켓·락을 가진 클래스는 복사 금지

## E. 동시성

- E1 인자·피연산자 둘 이상에 부작용이 있으면 지역 변수로 나눴다
- E2 C# `lock`을 `std::recursive_mutex`로 옮겼다 (`Monitor.Wait`는 `condition_variable_any`)
- E3 `volatile` → `std::atomic`, `Interlocked.CompareExchange` 인자 순서
- E4 `detach()`를 쓰지 않았다
- E5 나중에 실행되는 람다(`Post`·타이머·구독·스레드)에 `[&]`·`[=]`가 없고, 지역 변수를 이름을 적어 값 캡처했다. 람다를 넘긴 뒤 바뀌는 변수는 `shared_ptr`로 공유했다
- E11 나중에 실행되는 람다의 `this`는 수명이 보장된다(파괴 전 `Stop`·`Dispose`·`Unsubscribe`, 또는 `shared_from_this`). 아니면 보고했다
- E12 `main`에서 `InstallTerminateLogger()`를 부르고, 원본에 없는 `catch`로 작업 예외를 삼키지 않았다
- E6 스레드·타이머 예외 처리가 원본과 같다 (원본에 없는 `catch`를 추가하지 않았다)
- E7 `Invoke<T>`를 `InvokeWithResult<T>`로 옮겼다
- E8 타이머 모드(기본/건너뛰기)가 입력 C#과 같다
- E9 `IsBackground` 스레드에 종료 신호와 `join`이 있다 (없으면 보고)
- E10 `PREPORT-DECISION` 표식이 없는 보고 대상은 변환하지 않고 `TODO(PORT)`로 남겼다

## F. 직렬화·통신

- F1 필드 순서·크기가 C# `Write`/`Read`와 같다 (예약 필드 포함, `Write(식)`의 크기는 식의 정적 형식 기준)
- F2 `ByteWriter`/`ByteReader`의 바이트 순서가 원본 설정과 같다
- F3 문자열은 원본이 바이트로 바꾸는 지점에서만, 원본 인코딩으로 변환했다
- F4 `Read` 실패 시 원본 예외 처리와 같은 결과가 된다
- F5 팩토리 표 항목을 전부 옮겼고 개수를 적었다
- F6 `SO_REUSEADDR`, `SIO_UDP_CONNRESET`, 브로드캐스트 설정이 원본과 같다
- F7 TCP 수신은 누적 버퍼로 메시지 경계를 처리했다
