[FORMATTING.COMMENT.MISSING_SPACE_AFTER_DELIMITER] (C#)
설명
이 체커는 주석문장과 주석구분자(//) 사이에 공백이 있는지를 검출합니다.
취약점
주석문장과 주석구분자 사이에 공백이 없는 주석문
레퍼런스
MSDN C#:2015 코딩 규칙
3.4. 주석 구분 기호(//)와 주석 텍스트 사이에 공백을 하나 삽입합니다.
C# Coding conventions : 2023
주석 구분 기호(//)와 주석 텍스트 사이에 공백을 하나 삽입합니다.
예제 및 해결 방법
예제
1
public static void BadCase1()
2
{
3
  //BadCase1
4
  Console.WriteLine("BadCase1");
5
}
3번째 줄에서 주석문장과 주석구분자 사이에 공백이 없습니다.
해결 방법
1
public static void GoodCase1()
2
{
3
  // GoodCase1
4
  Console.WriteLine("GoodCase1");
5
}
3번째 줄처럼 주석문장과 주석 구분자 사이에 하나 이상의 공백이 넣어야 합니다.