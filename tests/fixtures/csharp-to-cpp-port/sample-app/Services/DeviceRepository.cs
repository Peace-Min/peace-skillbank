using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using SampleApp.Models;

namespace SampleApp.Services
{
    public class DeviceRepository
    {
        private readonly List<Device> _devices = new List<Device>();
        private readonly Dictionary<int, Device> _byId = new Dictionary<int, Device>();
        private readonly Logger _logger;

        public event EventHandler<Device> DeviceAdded;

        public DeviceRepository(Logger logger)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        }

        public int Count => _devices.Count;

        public void Add(Device device)
        {
            if (_byId.ContainsKey(device.Id))
            {
                throw new InvalidOperationException("duplicate id " + device.Id);
            }
            _devices.Add(device);
            _byId[device.Id] = device;
            _logger.Log("added " + device.Name);
            DeviceAdded?.Invoke(this, device);
        }

        public Device Find(int id)
        {
            Device found;
            return _byId.TryGetValue(id, out found) ? found : null;
        }

        public List<Device> FindByKind(DeviceKind kind)
        {
            return _devices
                .Where(d => d.Kind == kind)
                .OrderBy(d => d.Name, StringComparer.Ordinal)
                .ToList();
        }

        public async Task<int> RefreshAsync(int tick)
        {
            await Task.Delay(1);
            int touched = 0;
            foreach (Device d in _devices)
            {
                if (d.Kind != DeviceKind.Unknown)
                {
                    d.LastSeenTick = tick;
                    touched++;
                }
            }
            _logger.Log("refreshed " + touched);
            return touched;
        }
    }
}
