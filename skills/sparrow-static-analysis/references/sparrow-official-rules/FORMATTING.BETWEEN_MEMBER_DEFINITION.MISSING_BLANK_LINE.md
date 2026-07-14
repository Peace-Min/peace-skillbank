[FORMATTING.BETWEEN_MEMBER_DEFINITION.MISSING_BLANK_LINE] (C#)
설명
이 체커는 메소드나 프로퍼티 선언문들 사이에 한 줄 이상의 빈 줄이 있는지를 검출합니다.
취약점
타 메소드나 프로퍼티 선언문들과 빈줄이 없는 메소드나 프로퍼티 선언문
레퍼런스
MSDN C#:2015 코딩 규칙
2.5. 메서드 정의와 속성 정의 간에는 빈 줄을 하나 이상 추가합니다.
C# Coding conventions : 2023
메서드 정의와 속성 정의 간에는 빈 줄을 하나 이상 추가합니다.
예제 및 해결 방법
예제
1
public static void BadCase1_1()
2
{
3
  Console.WriteLine("Before BadCase1_1 method in class");
4
}
5
public static void BadCase1_2()
6
{
7
  Console.WriteLine("Current BadCase1_2 method in class");
8
}
1번째 줄에서 4번째 줄까지의 메소드 선언문과 5번째 줄에서 8번째 줄까지의 메소드 선언문 사이에 빈 줄이 없습니다.
해결 방법
1
public static void GoodCase1_1()
2
{
3
  Console.WriteLine("Before GoodCase1_1 method in class");
4
}
5
​
6
public static void GoodCase1_2()
7
{
8
  Console.WriteLine("Current GoodCase1_2 method in class");
9
}
1번째 줄에서 4번째 줄까지의 메소드 선언문과 6번째 줄에서 9번째 줄까지의 메소드 선언문 사이에 빈 줄이 있습니다.