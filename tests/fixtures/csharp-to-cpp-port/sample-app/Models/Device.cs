using System;
using SampleApp.Util;

namespace SampleApp.Models
{
    public class Device
    {
        public int Id { get; }
        public string Name { get; set; }
        public DeviceKind Kind { get; set; }
        public int? LastSeenTick { get; set; }

        public Device(int id, string name, DeviceKind kind)
        {
            if (name == null) throw new ArgumentNullException(nameof(name));
            Id = id;
            Name = name;
            Kind = kind;
            LastSeenTick = null;
        }

        public bool IsOnline => LastSeenTick.HasValue;

        public string Describe()
        {
            string seen = LastSeenTick.HasValue ? LastSeenTick.Value.ToString() : "never";
            return $"[{StringHelpers.PadId(Id)}] {Name} ({Kind}) seen={seen}";
        }

        public override string ToString()
        {
            return Describe();
        }
    }
}
