using System;
using System.IO;

namespace SampleApp.Services
{
    public sealed class Logger : IDisposable
    {
        private readonly StreamWriter _writer;
        private int _count;

        public Logger(string path)
        {
            if (!string.IsNullOrEmpty(path))
            {
                _writer = new StreamWriter(path, false);
            }
        }

        public int Count => _count;

        public void Log(string message)
        {
            string line = string.Format("LOG {0}: {1}", _count, message);
            _count++;
            if (_writer != null)
            {
                _writer.WriteLine(line);
            }
            else
            {
                Console.WriteLine(line);
            }
        }

        public void Dispose()
        {
            if (_writer != null)
            {
                _writer.Flush();
                _writer.Dispose();
            }
        }
    }
}
