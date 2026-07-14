[PRACTICE.OBJECT_INSTANTIATION.NOT_USED_IMPLICIT_TYPING] (C#)
설명
이 체커는 객체 인스턴스화 시 암시적 타입을 사용했는지를 검출합니다.
취약점
암시적 타입이 아니라 클래스 이름을 통해 객체를 인스턴스화 하는 문장
레퍼런스
MSDN C#:2015 코딩 규칙
10.1. 암시적 형식이 포함된 간결한 형태의 개체 인스턴스화를 사용합니다.
C# Coding conventions : 2023
암시적 형식이 포함된 간결한 형태의 개체 인스턴스화를 사용합니다.
예제 및 해결 방법
예제
1
public static void BadCase1()
2
{
3
  TestClass testClass1 = new TestClass();
4
  testClass1.print("BadCase1");
5
}
3번째 줄에서 객체 인스턴스화 시 암시적 타입을 사용하지 않고 클래스 이름을 사용하였습니다.
해결 방법
1
public static void GoodCase1()
2
{
3
  var testClass2 = new TestClass();
4
  testClass2.print("GoodCase1");
5
}
3번째 줄과 같이 객체 인스턴스화 시 암시적 타입을 사용해야 합니다.