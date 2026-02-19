package main

import vk "vendor:vulkan"

when ODIN_OS == .Windows {
	foreign import vulkan "system:vulkan-1.lib"
} else when ODIN_OS == .Linux {
	foreign import vulkan "system:vulkan"
}

@(default_calling_convention = "system")
foreign vulkan {
	@(link_name = "vkGetInstanceProcAddr")
	vk_get_instance_proc_addr :: proc(instance: vk.Instance, pName: cstring) -> vk.ProcVoidFunction ---
}


// To render the initial triangle w/ Vulkan:
// 1. get the vkInstance [x]
// 2. query it to get a vkPhysicalDevice [ ]
// 3. vkDevice (logical device)
// 4. window (glfw)
// 5. vkSurfaceKHR & vkSwapchainKHR [KHR -> extension postfix]
// - Send the window handle from the OS to the vulkan api (WSI - Window System Interface)
// swap chain -> collection of render targets

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

	if !features.geometryShader {
		return 0
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

main :: proc() {
	ms: Memory_System
	memory_system_initialize(&ms)
	defer memory_system_shutdown(&ms)

	vk.load_proc_addresses_global(cast(rawptr)vk_get_instance_proc_addr)

	app_info := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "OdinGame",
		applicationVersion = vk.MAKE_VERSION(0, 1, 0),
		pEngineName        = "NoEngine",
		engineVersion      = vk.MAKE_VERSION(0, 1, 0),
		apiVersion         = vk.API_VERSION_1_4,
	}

	exts := []cstring {
		"VK_KHR_surface",
		"VK_KHR_win32_surface", // Windows; for GLFW use its required extensions
	}

	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
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

	props: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(physical_device, &props)

	device_name := string(cast(cstring)&props.deviceName[0])
	log_infof("Selected physical device %s", device_name)
}
