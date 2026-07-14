[빈 catch 블록]
EMPTY_CATCH_BLOCK
 (C#)
설명
빈 예외 처리 블록 체커는 예외를 처리하는 코드 내용이 없는 예외 처리 블록을 검출합니다.
catch 블록 내에 실제 실행 코드가 없으면 검출됩니다.
빈 블록 안에 예외 처리 코드를 추가합니다. 특별히 처리할 것이 없다면 예외가 발생했었다는 오류 메시지를 남겨두는 것이 가장 무난합니다.
취약점
예외가 발생했을 때 예외를 잡아낸 후 아무 작업도 하지 않으면 프로그램 실행 시 오류가 발생했을 경우에 원인을 파악하기가 쉽지 않습니다.
레퍼런스
CWE
CWE-390 [CWE-390: Detection of Error Condition Without Action]
CWE-391 [CWE-391: Unchecked Error Condition]
OWASP
Top 10 2004-A07-Improper Error Handling
Top 10 2007-A06-Information Leakage and Improper Error Handling
Top 10 2017-A06-Security Misconfiguration
Uncaught exception
행안부 보안약점 2021
04.02. 오류 상황 대응 부재 [시스템 오류상황을 처리하지 않아 프로그램 실행정지 등 의도하지 않은 상황이 발생 가능한 보안약점]
행안부 보안약점 2019
04.02. 오류 상황 대응 부재
무기체계 소프트웨어 보안약점 점검 목록
CWE-390
예제 및 해결 방법
예제
1
public void DoSome() {   
2
  try {
3
    InvokeMtd();
4
  } catch (Exception e) {
5
    /* BUG */
6
  }
7
}
라인 5: catch 블록에서 오류를 포착하고 있지만 아무런 조치를 취하고 있지 않습니다.
해결 방법
1
public void DoSome() { 
2
  try {
3
    InvokeMtd();
4
  } catch (Exception e) {
5
    logger.Debug("log message"); //Leave a message in the log or handle the error properly in other ways.
6
  }
7
}
라인 5: 예외를 포착한 후 각각의 예외사항에 대하여 적절하게 처리하도록 합니다.