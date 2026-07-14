[PRACTICE.LOOP_VARIABLE.NOT_USED_IMPLICIT_TYPING] (C#)
설명
이 체커는 for문과 foreach문의 루프변수 타입이 암시적 타입인지 검출합니다.
취약점
루프변수의 타입이 암시적 타입이 아닌 'for'문과 'foreach'문
레퍼런스
MSDN C#:2015 코딩 규칙
5.5. for 및 foreach 루프의 루프 변수 형식을 결정하려면 암시적 형식을 사용합니다. [5.5. for 및 foreach 루프의 루프 변수 형식을 결정하려면 암시적 형식을 사용합니다.]
C# Coding conventions : 2023
for 및 foreach 루프의 루프 변수 형식을 결정하려면 암시적 형식을 사용합니다.
예제 및 해결 방법
예제
1
public static void BadCase1()
2
{
3
  var syllable = "ha";
4
  var laugh = "";
5
​
6
  Console.WriteLine("BadCase1-1 :");
7
​
8
  for (int i = 0; i < 10; i++)    // use 'int' type.
9
  {
10
    laugh += syllable;
11
    Console.WriteLine(laugh);
12
  }
13
​
14
  Console.WriteLine("BadCase1-2 :");
15
​
16
  foreach(char ch in laugh)   // use 'char' type.
17
  {
18
    if (ch == 'h')
19
      Console.Write("H");
20
    else
21
      Console.Write(ch);
22
  }
23
  Console.WriteLine();
24
}
8번째 줄에서 for문의 루프변수 타입으로 int타입을 사용하였습니다. 또한, 16번째 줄에서 foreach문의 루프변수 타입으로 char타입을 사용하였습니다.
해결 방법
1
public static void GoodCase1()
2
{
3
  var syllable = "ha";
4
  var laugh = "";
5
​
6
  Console.WriteLine("GoodCase1-1 :");
7
​
8
  for (var i = 0; i < 10; i++)
9
  {
10
    laugh += syllable;
11
    Console.WriteLine(laugh);
12
  }
13
​
14
  Console.WriteLine("GoodCase1-2 :");
15
​
16
  foreach (var ch in laugh)
17
  {
18
    if (ch == 'h')
19
      Console.Write("H");
20
    else
21
      Console.Write(ch);
22
  }
23
  Console.WriteLine();
24
}
8번째 줄과 16번째 줄처럼, for문과 foreach문의 루프변수 타입은 암시적 타입을 사용해야 합니다.