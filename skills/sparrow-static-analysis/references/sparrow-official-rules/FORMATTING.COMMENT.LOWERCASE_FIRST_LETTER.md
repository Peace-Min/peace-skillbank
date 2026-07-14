[FORMATTING.COMMENT.LOWERCASE_FIRST_LETTER] (C#)
설명
이 체커는 주석 문장이 대문자로 시작되는지를 검출합니다.
취약점
소문자로 시작되는 주석 문장
레퍼런스
MSDN C#:2015 코딩 규칙
3.2. 주석 텍스트는 대문자로 시작합니다.
C# Coding conventions : 2023
주석 텍스트는 대문자로 시작합니다.
예제 및 해결 방법
예제
1
public static void BadCase1()
2
{
3
  // badCase1
4
  Console.WriteLine("BadCase1");  
5
}
3번째 줄의 주석 문장이 대문자가 아니라 소문자로 시작되었습니다.
해결 방법
1
public static void GoodCase1()
2
{
3
  // GoodCase1.
4
  Console.WriteLine("GoodCase1"); 
5
}
3번째 줄의 주석 문장이 대문자로 시작해야 합니다.