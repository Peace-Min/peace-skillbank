## Toolchain (fixed for the project)

| Decision | Value |
|---|---|
| Target | Windows only, modern C++17 (C++20 features are not used unless the project sets `-Standard c++20`), MSVC (VS 2019/2022) or MinGW-w64 |
| String type | `std::wstring` (UTF-16, same as .NET `string`); literals `L"..."`; `wchar_t` |
| Support header | `#include "PortSupport.h"` (namespace `PortSupport`, fixed, already in the C++ root). Use it instead of inventing helpers. |
| Entry point | `int wmain(int argc, wchar_t* argv[])`; first line `PortSupport::InitConsole();` |
| Console | `std::wcout << ... << L'\n'` and `std::wcerr` (never `std::cout`, `printf`, `wprintf`) |
| File layout | one C# file -> `<same relative path>.h` + `.cpp`; `#pragma once`; `#include "Dir/File.h"` relative to the C++ root |
| Namespaces | `namespace A::B { ... }` mirrors the C# namespace |
| Exceptions | `throw std::invalid_argument("name")` (ArgumentException/ArgumentNull), `std::logic_error` (InvalidOperation), `std::out_of_range` (IndexOutOfRange/KeyNotFound), `std::runtime_error` (others). The message is a narrow ASCII literal, optionally `+ std::to_string(number)`. Never put a `std::wstring` in an exception message. |

## Modern C++ idioms (mandatory)

| Rule | Form |
|---|---|
| Ownership | follow the "Ownership (computed)" list in the prompt: SHARED -> `std::shared_ptr<T>` + `std::make_shared`; SINGLE -> plain value member/local; SINGLE + polymorphic -> `std::unique_ptr<T>` + `std::make_unique`. Never raw `new`/`delete`. |
| Non-owning access | `const T&` / `T&` parameters for values; pass `std::shared_ptr<T>` by value for SHARED types |
| Getters | `[[nodiscard]] Type Name() const noexcept` for trivial getters; `const std::wstring&` for string getters |
| Destructors | `~T() noexcept` (the default); `= default` when trivial |
| Copy control | RAII types (files, mutexes, handles): `T(const T&) = delete; T& operator=(const T&) = delete;` |
| Virtual | `virtual` in the base, `override` in derived, `final` on leaf classes that C# marked `sealed` when they have a base |
| Constants | `constexpr` for `const` literals; `static constexpr` for class constants; `inline constexpr` in headers |
| Locals | `auto` when the type is obvious from the initializer (`auto it = map.find(k);`); range-for over containers |
| Casts | `static_cast` only; no C-style casts |
| Null | `nullptr`; `std::optional<T>` for "may be absent" values that are not SHARED pointers |
| Aliases | `using Name = ...;` never `typedef` |
| Enums | `enum class` |
| Init | member initialisers in the header (`int count_ = 0;`), constructor initialiser lists, `{}` for aggregates |

## Types

| C# | C++ |
|---|---|
| `string` | `std::wstring` (cannot be null). If C# distinguishes `null` from `""` (sentinel returns, `??`), use `std::optional<std::wstring>` |
| `char` | `wchar_t` |
| `int` / `uint` / `long` / `ulong` / `short` / `ushort` / `byte` / `sbyte` | `int` / `unsigned int` / `long long` / `unsigned long long` / `short` / `unsigned short` / `unsigned char` / `signed char` |
| `bool` / `double` / `float` | `bool` / `double` / `float` |
| `decimal` | `double` with `// TODO(port): decimal precision` |
| `T?` (nullable value) | `std::optional<T>` |
| `object` | avoid; if unavoidable `std::any` with `// TODO(port)` |
| `T[]` / `List<T>` / `IList<T>` | `std::vector<T>` (elements are `std::shared_ptr<T>` when `T` is SHARED) |
| `IEnumerable<T>` parameter / return | `const std::vector<T>&` / `std::vector<T>` |
| `Dictionary<K,V>` | `std::unordered_map<K,V>`. .NET enumerates in insertion order; C++ does not. If output depends on that order, keep a `std::vector<K>` of insertion order next to the map |
| `HashSet<T>` | `std::unordered_set<T>` |
| `Queue<T>` / `Stack<T>` | `std::deque<T>` / `std::vector<T>` |
| `KeyValuePair<K,V>` | `std::pair<K,V>` |
| `Tuple` / value tuples | `std::tuple` or a small struct; structured bindings at the use site |
| `DateTime` / `TimeSpan` | `std::chrono::system_clock::time_point` / `std::chrono::milliseconds` |
| `Guid` | `std::wstring` holding the canonical text form |
| `enum` | `enum class` + `XToString(X)` + `bool TryParseX(const std::wstring&, X&)` in the same header; `TryParseX` accepts numeric text (`"2"`) like `Enum.TryParse`, and names case-insensitively only where the C# call passed `ignoreCase: true` (otherwise exact) |
| generic `class Repo<T>` / `interface IRepo<T>` | `template <typename T> class Repo` with EVERY member defined in the `.h`; the `.cpp` contains only `#include "...h"` (templates cannot live in a .cpp) |
| `struct` (value type) | `struct` with every member initialised (`int x = 0;`), because C# zero-initialises |
| `interface` | abstract class: pure virtual functions, `virtual ~I() = default;` |
| `abstract` / `virtual` / `override` / `sealed` | same keywords; `override` on every overriding function; `final` for `sealed` classes with a base |
| `static class` | `namespace` of free functions |
| `delegate` / `Func<>` / `Action<>` | `std::function<...>` |
| `event EventHandler<T> X` | private `std::vector<std::function<void(const T&)>>` + public `void SubscribeX(handler)`; raise by looping |
| `EventHandler` (non-generic, `(object sender, EventArgs e)`) | `std::vector<std::function<void()>>` + `SubscribeX(handler)`; the sender is dropped |
| `IDisposable` / `Dispose()` | destructor does the cleanup (RAII); delete copy ctor/assignment; keep a public `Dispose()` only if callers call it explicitly |
| `using (var x = ...) { }` | a `{ }` block; the object is a local |
| `async Task<T> M()` / `async Task M()` | plain synchronous `T M()` / `void M()`; `await x` -> `x`; `Task.Delay(n)` -> `std::this_thread::sleep_for(std::chrono::milliseconds(n))`; `Task.Run(f)` -> call `f()`; add `// TODO(port): was async` on the declaration. Real concurrency is a human decision later. |
| `.Result` / `.GetAwaiter().GetResult()` / `.Wait()` | just the call |
| `lock (obj)` | `std::lock_guard<std::recursive_mutex>` on a `std::recursive_mutex` member (C# Monitor is re-entrant) |
| `Thread` / `ThreadPool` / `Timer` | `// TODO(port): threading` and a synchronous call; do not introduce threads |
| `[DllImport]` | direct Win32 call (`PortSupport.h` already includes `<windows.h>`) behind the same function name |
| LINQ `Where` / `Select` / `OrderBy` / `First` / `FirstOrDefault` / `Any` / `All` / `Count` / `Sum` / `ToList` / `ToArray` | `std::copy_if` / loop / `std::stable_sort` / `std::find_if` (+ `nullptr` or `std::optional` for `OrDefault`) / `std::any_of` / `std::all_of` / `std::count_if` / `std::accumulate` / return the vector |
| `yield return` | build a `std::vector<T>` and return it |
| `string.Format` / `$"..."` / `+` | `std::wstring` concatenation with `PortSupport::ToWString(x)` for every non-string operand |
| number `.ToString()` | `PortSupport::ToWString(x)` (double is "G15", bool is `True`/`False`) |
| `.ToString("F2")` | `PortSupport::ToFixed(x, 2)` (Framework rounding: 2.675 -> `2.68`) |
| `.ToString("N2")` (thousands separators) | `PortSupport::ToFixed(x, 2)` + `// TODO(port): N-format group separators` |
| `DateTime.Now` / `.ToString("yyyy-MM-dd HH:mm:ss")` | `std::chrono::system_clock::now()` + `std::put_time` with the pattern translated (`%Y-%m-%d %H:%M:%S`); other patterns `// TODO(port): date format` |
| `string.Join(sep, list)` / `string.Compare(a, b)` / `.IndexOf(s)` / `.ToLower()` | loop with `+=` / `a.compare(b)` / `.find(s)` (`npos` -> -1) / `std::towlower` per char |
| `Math.Round(x, digits)` | `std::nearbyint(x * 10^digits) / 10^digits` |
| `int.Parse` / `double.Parse` / `TryParse` | `std::stoi` / `std::stod` inside `try` / `catch (const std::exception&)` returning `false` |
| `string.IsNullOrEmpty` / `IsNullOrWhiteSpace` | `.empty()` / loop with `std::iswspace` |
| `StringBuilder` | `std::wstring` with `reserve` and `+=` |
| `.Split(c)` / `.Trim()` / `.ToUpper()` / `.Contains()` / `.StartsWith()` / `.Replace(a,b)` / `.Substring` / `.PadLeft` | small loops or `std::wstring` members (`find`, `substr`, `insert`); `std::towupper` per char |
| `StreamWriter` (text file) | `std::ofstream` from `PortSupport::OpenTextFile(path)` + `PortSupport::WriteLine(file, line)` (UTF-8). Never `std::wofstream`: it drops non-ASCII silently |
| `StreamReader` / `File.ReadAllLines` | `PortSupport::OpenTextFileForRead` + `PortSupport::ReadLine` |
| `File.Exists` / `Directory.*` / `Path.Combine` | `std::filesystem` |
| `Console.WriteLine(x)` / `Console.Error.WriteLine(x)` | `std::wcout << x << L'\n'` / `std::wcerr << ...` (numbers and bools through `PortSupport::ToWString`) |
| `Math.Round(x)` | `std::nearbyint(x)` (banker's rounding like .NET), not `std::round` |
| `Math.Max/Min/Abs/Sqrt` | `std::max/min/abs/sqrt` from `<algorithm>` / `<cmath>` |
| `Environment.NewLine` | `L"\r\n"` |
| `Stopwatch` | `std::chrono::steady_clock` |
| `Random` | `std::mt19937` seeded once; sequences will differ from .NET (`// TODO(port): rng sequence`) |
| `[Flags] enum` | `enum class X : unsigned int` + free `operator\|`, `operator&`, `operator\|=` and `HasFlag(x, f)` in the same header |
| `System.Windows.Media.Color` / `System.Drawing.Color` | a value struct in the unit that needs it: `struct Color { unsigned char A = 255, R = 0, G = 0, B = 0; };`. Named colours (`Colors.Red`) become `constexpr Color` constants. It is data, not UI: port it even when the UI framework is undecided |
| `Point` / `Size` / `Rect` / `Thickness` / `Vector` | small value structs with the same field names (`struct Point { double X = 0, Y = 0; };`) |
| `Brush` / `Pen` / `ImageSource` / any `DependencyObject` | not data: do not port; `// TODO(port): UI object <name>` and leave it to the UI-framework decision |
| `ConfigurationManager.AppSettings["k"]` | `PortSupport::AppSetting(L"k")` (+ `AppSettingInt` / `AppSettingBool` / `AppSettingDouble`). Run `scripts/convert-appconfig.ps1` once to turn App.config into the `.ini` it reads |
| `ConnectionStrings` / custom config sections | `// TODO(port): config section <name>`; convert-appconfig.ps1 does not touch them |
| `Properties.Settings.Default.X` | same as appSettings via `PortSupport::AppSetting(L"X")` + `// TODO(port): user-scoped setting` if it was writable |
| `Properties.Resources.X` (strings) | a `constexpr wchar_t*` or `inline const std::wstring` constant next to its use; images `// TODO(port): resource <name>` |
| `#region` / `#endregion` | drop |
| `#if DEBUG ... #else ... #endif` | keep only the non-DEBUG branch |
