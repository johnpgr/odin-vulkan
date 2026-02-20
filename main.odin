package main

import glfw "vendor:glfw"
import vk "vendor:vulkan"

when ODIN_OS == .Windows {
	foreign import vulkan "system:vulkan-1.lib"
} else when ODIN_OS == .Linux {
	foreign import vulkan "system:vulkan"
} else when ODIN_OS == .Darwin {
	foreign import vulkan "system:vulkan"
}

@(default_calling_convention = "system")
foreign vulkan {
	@(link_name = "vkGetInstanceProcAddr")
	vkGetInstanceProcAddr :: proc(instance: vk.Instance, pName: cstring) -> vk.ProcVoidFunction ---
}

find_graphics_queue_family :: proc(device: vk.PhysicalDevice, ms: ^Memory_System) -> (u32, bool) {
	frame := memory_begin_frame_temp(ms)
	defer memory_end_frame_temp(&frame)

	queue_family_count: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
	if queue_family_count == 0 {
		return 0, false
	}

	queue_families := make([]vk.QueueFamilyProperties, int(queue_family_count), frame.allocator)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		device,
		&queue_family_count,
		raw_data(queue_families),
	)

	for i in 0 ..< int(queue_family_count) {
		q := queue_families[i]
		if q.queueCount > 0 && (.GRAPHICS in q.queueFlags) {
			return u32(i), true
		}
	}

	return 0, false
}

device_extension_available :: proc(
	device: vk.PhysicalDevice,
	name: cstring,
	ms: ^Memory_System,
) -> bool {
	count: u32 = 0
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) != .SUCCESS || count == 0 {
		return false
	}

	frame := memory_begin_frame_temp(ms)
	defer memory_end_frame_temp(&frame)

	props := make([]vk.ExtensionProperties, int(count), frame.allocator)

	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, raw_data(props)) != .SUCCESS {
		return false
	}

	target := string(name)
	for i in 0 ..< int(count) {
		ext_name := string(cast(cstring)&props[i].extensionName[0])
		if ext_name == target {
			return true
		}
	}
	return false
}

Logical_Device_And_Queue :: struct {
	device:       vk.Device,
	queue:        vk.Queue,
	family_index: u32,
}

create_logical_device_and_queue :: proc(
	physical_device: vk.PhysicalDevice,
	ms: ^Memory_System,
) -> (
	Logical_Device_And_Queue,
	bool,
) {
	graphics_family_index, ok := find_graphics_queue_family(physical_device, ms)
	if !ok {
		return {}, false
	}

	queue_priority: f32 = 1.0
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = graphics_family_index,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}

	device_features := vk.PhysicalDeviceFeatures{}

	enabled_ext_count: u32 = 0
	enabled_ext_ptr: ^cstring = nil
	portability_subset: cstring = vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME
	if device_extension_available(physical_device, portability_subset, ms) {
		enabled_ext_count = 1
		enabled_ext_ptr = &portability_subset
	}

	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		pEnabledFeatures        = &device_features,
		enabledExtensionCount   = enabled_ext_count,
		ppEnabledExtensionNames = enabled_ext_ptr,
	}

	device: vk.Device

	if vk.CreateDevice(physical_device, &create_info, nil, &device) != .SUCCESS {
		return {}, false
	}

	vk.load_proc_addresses_device(device)

	graphics_queue: vk.Queue
	vk.GetDeviceQueue(device, graphics_family_index, 0, &graphics_queue)

	return {device, graphics_queue, graphics_family_index}, true
}

has_graphics_queue_family :: proc(device: vk.PhysicalDevice, ms: ^Memory_System) -> bool {
	frame := memory_begin_frame_temp(ms)
	defer memory_end_frame_temp(&frame)

	queue_family_count: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
	if queue_family_count == 0 {
		return false
	}

	queue_families := make([]vk.QueueFamilyProperties, int(queue_family_count), frame.allocator)

	vk.GetPhysicalDeviceQueueFamilyProperties(
		device,
		&queue_family_count,
		raw_data(queue_families),
	)

	for q in queue_families {
		if q.queueCount > 0 && (.GRAPHICS in q.queueFlags) {
			return true
		}
	}

	return false
}

rate_device_suitability :: proc(device: vk.PhysicalDevice, ms: ^Memory_System) -> int {
	props: vk.PhysicalDeviceProperties
	features: vk.PhysicalDeviceFeatures

	vk.GetPhysicalDeviceProperties(device, &props)
	vk.GetPhysicalDeviceFeatures(device, &features)

	when ODIN_OS != .Darwin {
		if !features.geometryShader {
			return 0
		}
	}

	if !has_graphics_queue_family(device, ms) {
		return 0
	}

	score := int(props.limits.maxImageDimension2D)
	if props.deviceType == .DISCRETE_GPU {
		score += 1000
	}

	return score
}

pick_physical_device :: proc(
	instance: vk.Instance,
	ms: ^Memory_System,
) -> (
	vk.PhysicalDevice,
	bool,
) {
	device_count: u32 = 0

	if vk.EnumeratePhysicalDevices(instance, &device_count, nil) != .SUCCESS || device_count == 0 {
		return {}, false
	}

	frame := memory_begin_frame_temp(ms)
	defer memory_end_frame_temp(&frame)

	devices := make([]vk.PhysicalDevice, int(device_count), frame.allocator)

	if vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices)) != .SUCCESS {
		return {}, false
	}

	best_score := -1
	best_device: vk.PhysicalDevice
	found := false

	for d in devices {
		score := rate_device_suitability(d, ms)
		if score > best_score {
			best_score = score
			best_device = d
			found = true
		}
	}

	if !found || best_score <= 0 {
		return {}, false
	}

	return best_device, true
}

has_extension_name :: proc(exts: []cstring, target: cstring) -> bool {
	target_name := string(target)
	for ext in exts {
		if ext != nil && string(ext) == target_name {
			return true
		}
	}
	return false
}

instance_extension_available :: proc(name: cstring, ms: ^Memory_System) -> bool {
	count: u32 = 0
	if vk.EnumerateInstanceExtensionProperties(nil, &count, nil) != .SUCCESS || count == 0 {
		return false
	}

	frame := memory_begin_frame_temp(ms)
	defer memory_end_frame_temp(&frame)

	props := make([]vk.ExtensionProperties, int(count), frame.allocator)
	if vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(props)) != .SUCCESS {
		return false
	}

	name_str := string(name)
	for i in 0 ..< int(count) {
		ext_name := string(cast(cstring)&props[i].extensionName[0])
		if ext_name == name_str {
			return true
		}
	}

	return false
}

// To render the initial triangle w/ Vulkan:
// 1. get the vkInstance [x]
// 2. query it to get a vkPhysicalDevice [x]
// 3. create a vkDevice (logical device) [ ]
// 4. specify which queue families to use [ ]
// 5. window (glfw)
// 6. vkSurfaceKHR & vkSwapchainKHR [KHR -> extension postfix]
// - Send the window handle from the OS to the vulkan api (WSI - Window System Interface)
// swap chain -> collection of render targets
main :: proc() {
	ms: Memory_System
	memory_system_initialize(&ms)
	defer memory_system_shutdown(&ms)

	if !glfw.Init() {
		log_error("glfwInit failed")
		return
	}
	defer glfw.Terminate()

	if !glfw.VulkanSupported() {
		log_error("GLFW reports Vulkan unsupported")
		return
	}

	vk.load_proc_addresses_global(cast(rawptr)vkGetInstanceProcAddr)

	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "OdinGame",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "NoEngine",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		apiVersion         = vk.API_VERSION_1_4,
	}

	required_exts := glfw.GetRequiredInstanceExtensions()
	if len(required_exts) == 0 {
		log_error("GLFW returned no Vulkan instance extensions")
		return
	}

	portability_ext: cstring = vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
	enable_portability := instance_extension_available(portability_ext, &ms)
	append_portability_name :=
		enable_portability && !has_extension_name(required_exts, portability_ext)

	ext_count := len(required_exts)
	if append_portability_name {
		ext_count += 1
	}

	exts := make([]cstring, ext_count)
	copy(exts, required_exts)
	if append_portability_name {
		exts[len(required_exts)] = portability_ext
	}

	create_flags := vk.InstanceCreateFlags{}
	if enable_portability {
		create_flags = {.ENUMERATE_PORTABILITY_KHR}
	}

	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		flags                   = create_flags,
		pApplicationInfo        = &app_info,
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
	}

	instance: vk.Instance
	res := vk.CreateInstance(&create_info, nil, &instance)
	if res != .SUCCESS {
		log_error("vkCreateInstance failed:", res)
		return
	}
	log_info("Vulkan instance created!")

	defer vk.DestroyInstance(instance, nil)
	vk.load_proc_addresses_instance(instance)

	physical_device, ok := pick_physical_device(instance, &ms)
	if !ok {
		log_error("Failed to find a suitable GPU device")
		return
	}

    // Log out the phisycal device info
	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(physical_device, &props)
	device_name := string(cast(cstring)&props.deviceName[0])
	log_infof("Selected physical device %s", device_name)

    device_and_queue, ok_device_queue := create_logical_device_and_queue(physical_device, &ms)
    if !ok_device_queue {
        log_error("Failed to create logical device")
        return
    }
    defer vk.DestroyDevice(device_and_queue.device, nil)

    log_infof("Logical device created, graphics family=%d", device_and_queue.family_index)
    _ = device_and_queue.queue
}
