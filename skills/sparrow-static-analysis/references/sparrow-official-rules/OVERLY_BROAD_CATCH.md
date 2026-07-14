[지나치게 일반적인 예외 처리] (C#)
설명
지나치게 일반적인 예외 처리 체커는 너무 다양한 예외를 포괄적으로 처리하는 코드를 검출합니다.
가장 상위 예외를 사용하여 catch하는 것을 자제해야 합니다.
해당 코드 구역에서 발생할 수 있는 세부적인 예외들을 명시적으로 나눠서 처리하는 것이 좋습니다. 일반적인 예외를 처리하더라도 예측 가능한 세부적인 예외들을 먼저 처리한 후 마지막에 처리하도록 합니다. 이렇게 작성했을 때 실행 흐름이 일반적인 예외 처리 부분에 도달했다면 개발 과정에서 예측하지 못한 예외가 발생한 것이므로 조용히 넘어가지 않고 상황에 대한 상세한 기록을 남겨서 추후 결함을 수정할 수 있도록 합니다.
취약점
지나치게 일반적인 예외 처리를 하게 되면 특별히 처리해야 하는 개별 예외를 적절히 처리하지 못할 뿐 아니라 이 지점에서 논리적으로 발생해서는 안되는 예외까지 처리하게 됩니다. 이러한 경우에 개발 및 검수 과정에서 발견되었어야 하는 설계 및 구현 상 결함이 발견되지 못한 채 배포 단계로 넘어가서 더 큰 문제의 원인이 될 수 있습니다.
레퍼런스
CWE
CWE-396 [CWE-396: Declaration of Catch for Generic Exception]
CWE-754 [CWE-754: Improper Check for Unusual or Exceptional Conditions]
CWE 660 List
Declaration of Catch for Generic Exception - (396) [Catching overly broad exceptions promotes complex error handling code that is more likely to contain security vulnerabilities.]
행안부 보안약점 2021
04.03. 부적절한 예외처리 [예외사항을 부적절하게 처리하여 의도하지 않은 상황이 발생 가능한 보안약점]
행안부 보안약점 2019
04.03. 부적절한 예외처리
CWE-660(4.7)
Declaration of Catch for Generic Exception - (396)
무기체계 소프트웨어 보안약점 점검 목록
CWE-755
예제 및 해결 방법
예제
1
try { 
2
  // do something
3
} catch (Exception e) { 
4
  Logger.Error("log here", e); /* BUG */
5
}
라인 3: 가장 상위 Exception으로 처리하고 있습니다.
해결 방법
1
try { 
2
  // do something
3
} catch (IOException e) { 
4
  Logger.Error("log here", e);
5
} catch (SQLException e) {
6
  Logger.Error("log here", e);
7
}
라인 3: 각 예외 상황에 대한 처리 방법을세분화 합니다.