[PRACTICE.OBVIOUS_VARIABLE_TYPE.NOT_USED_IMPLICIT_TYPING] (C#)
설명
이 체커는 할당문을 통해 명확한 타입 유추가 가능하거나 타입이 중요하지 않을 때 암시적 타입을 사용했는지 검출합니다.
취약점
할당문을 통해 명확한 타입 유추가 가능하거나 타입이 중요하지 않음에도 암시적 타입을 사용하지 않은 지역 변수 선언문
레퍼런스
MSDN C#:2015 코딩 규칙
5.1. 할당 오른쪽에서 변수 형식이 명확하거나 정확한 형식이 중요하지 않으면 지역 변수에 대해 암시적 형식을 사용합니다. [5.1. 할당 오른쪽에서 변수 형식이 명확하거나 정확한 형식이 중요하지 않으면 지역 변수에 대해 암시적 형식을 사용합니다.]
C# Coding conventions : 2023
할당 오른쪽에서 변수 형식이 명확하거나 정확한 형식이 중요하지 않으면 지역 변수에 대해 암시적 형식을 사용합니다.
예제 및 해결 방법
예제
1
public static void BadCase1()
2
{
3
  string var1 = "This is clearly a string.";
4
  int var2 = 27;
5
  Int32 var3 = Convert.ToInt32(Console.ReadLine());
6
​
7
  Console.WriteLine("BadCase1 :");
8
  Console.WriteLine(var1);
9
  Console.WriteLine(var2);
10
  Console.WriteLine(var3);
11
}
3번째 줄에서부터 5번째 줄에 있는 선언문은 할당문을 통해 명확한 타입 유추가 가능함에도 암시적 타입을 사용하지 않았습니다.
해결 방법
1
public static void GoodCase1()
2
{
3
  var var1 = "This is clearly a string.";
4
  var var2 = 27;
5
  var var3 = Convert.ToInt32(Console.ReadLine());
6
​
7
  Console.WriteLine("GoodCase1");
8
  Console.WriteLine(var1);
9
  Console.WriteLine(var2);
10
  Console.WriteLine(var3);
11
}
3번째 줄에서부터 5번째 줄까지처럼 할당문을 통해 명확한 타입 유추가 가능하면 암시적 타입을 사용해야 합니다.