#include <memory>
#include <AudioServerPlugIn.h>
#include "aspl/Context.h"
#include "aspl/Device.h"
#include "aspl/Driver.h"
#include "aspl/Plugin.h"

// Minimal libASPL driver: one virtual output device.
static std::shared_ptr<aspl::Driver> CreateDriver() {
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters params;
    params.Name = "retune Virtual Output";
    params.Manufacturer = "retune";
    params.SampleRate = 48000;
    params.ChannelCount = 2;
    params.EnableMixing = true;

    auto device = std::make_shared<aspl::Device>(context, params);
    device->AddStreamWithControlsAsync(aspl::Direction::Output);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

extern "C" void* EntryPoint(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
