[FORMATTING.COMMENT.MISSING_PERIOD] (C#)
설명
이 체커는 주석이 마침표나 물음표, 느낌표로 끝나는지를 확인합니다.
취약점
종결 문장 부호로 끝나지 않는 주석문
레퍼런스
MSDN C#:2015 코딩 규칙
3.3. 주석 텍스트 끝에는 마침표를 붙입니다.
C# Coding conventions : 2023
주석 텍스트 끝에는 마침표를 붙입니다.
예제 및 해결 방법
예제
1
public static void BadCase1()
2
{
3
  // BadCase1
4
  Console.WriteLine("BadCase1");
5
}
3번째 줄의 주석의 문장 끝에 종결 문장 부호가 없습니다.
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
3번째 줄의 주석의 문장 끝에 종결 문자 부호를 넣어 주어야 합니다.