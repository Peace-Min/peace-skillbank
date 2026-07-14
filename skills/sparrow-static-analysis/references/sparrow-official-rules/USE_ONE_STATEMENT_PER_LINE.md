[한 줄에 작성된 여러 개의 구문(방위사업청)] (C#)
설명
이 체커는 한 줄에 하나의 문장만 사용되었는지를 검출합니다.
취약점
한 줄에 여러 문장이 있는 문장들
레퍼런스
MSDN C#:2015 코딩 규칙
2.2. 문을 한 줄에 하나씩만 작성합니다.
C# Coding conventions : 2023
문을 한 줄에 하나씩만 작성합니다.
예제 및 해결 방법
예제
1
public static void BadCase1()
2
{
3
  Console.WriteLine("BadCase1 - 1"); Console.WriteLine("BadCase1 - 2");
4
}
3번째 줄에서, 한 줄에 여러 문장이 있습니다.
해결 방법
1
public static void GoodCase1()
2
{
3
  Console.WriteLine("GoodCase1 - 1");
4
  Console.WriteLine("GoodCase1 - 2");
5
}
3번째 줄과 4번째 줄처럼 한 줄에 하나의 문장만 써야 합니다.