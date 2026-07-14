[FORMATTING.COMMENT.BLOCK_OF_ASTERISK] (C#)
설명
이 체커는 주석문장을 감싸는 별표(*) 블록을 사용하였는지 검출합니다.
취약점
주석문장을 감싸는 별표(*) 블록을 사용한 주석문
레퍼런스
MSDN C#:2015 코딩 규칙
3.5. 서식이 지정된 별표 블록으로 주석을 묶지 않습니다.
C# Coding conventions : 2023
서식이 지정된 별표 블록으로 주석을 묶지 않습니다.
예제 및 해결 방법
예제
1
public static void BadCase1()
2
{
3
  /* BadCase1
4
   * BadCase1
5
   * BadCase1 */
6
  Console.WriteLine("BadCase1");
7
}
3번째 줄에서 5번째 줄까지처럼 주석문장을 감싸는 별표(*) 블록을 사용하였습니다.
해결 방법
1
public static void GoodCase1()
2
{
3
  /* GoodCase1
4
     GoodCase1
5
     GoodCase1 */
6
  Console.WriteLine("GoodCase1");
7
}
3번째 줄에서 5번째 줄까지와 같이 주석문장을 감싸는 별표(*) 블록을 사용하지 않았습니다.