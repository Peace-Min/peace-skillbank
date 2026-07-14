[FORMATTING.CONTINUATION_LINE.BAD_INDENTATION] (C#)
설명
이 체커는 하나의 문장이 여러 줄에 걸쳐 있는 경우 자동으로 들여쓰기가 되어 있는지 검출합니다.
취약점
들여쓰기가 되어 있지 않은, 여러 줄에 걸여 있는 문장
레퍼런스
MSDN C#:2015 코딩 규칙
2.4. 연속 줄이 자동으로 들여쓰기되지 않으면 탭 정지 하나(공백 4개)만큼 들여씁니다.
C# Coding conventions : 2023
연속 줄이 자동으로 들여쓰기되지 않으면 탭 정지 하나(공백 4개)만큼 들여씁니다.
예제 및 해결 방법
예제
1
public static void BadCase1()
2
{
3
  if(20 > 10  // dose not indent
4
  && 30 > 10)
5
  {
6
    Console.WriteLine("BadCase1_1");
7
  }
8
​
9
  while(20 > 10   // dose not indent
10
  && 30 > 10)
11
  {
12
    Console.WriteLine("BadCase1_2");
13
    break;
14
  }
15
}
3번째 줄에서 4번째 줄까지 걸쳐있는 if문 안의 조건문이 들여쓰기가 되어 있지 않습니다. 또한, 9번째 줄에서 10번째 줄에 걸쳐 있는 while문 안의 조건문도 들여쓰기가 되어 있지 않습니다.
해결 방법
1
public static void GoodCase1()
2
{
3
  if(20 > 10
4
     && 30 > 10)
5
  {
6
    Console.WriteLine("GoodCase1_1");
7
  }
8
​
9
  while(20> 10
10
        && 30 > 10)
11
  {
12
    Console.WriteLine("GoodCase1_2");
13
    break;
14
  }
15
}
4번째 줄과 10번째 줄처럼 하나의 문장이 여러 줄에 걸쳐 쓰여진 경우 하나의 탭(또는 빈칸4개)만큼 들여쓰기 해 주어야 합니다.
(이 예시에서는 빈칸1개를 하나의 탭으로 취급합니다.)