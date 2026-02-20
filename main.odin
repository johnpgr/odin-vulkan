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

QueueFamilyIndices :: struct {
	graphics_family: u32,
	present_family:  u32,
}

find_queue_families :: proc(
	device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
) -> (
	QueueFamilyIndices,
	bool,
) {
	// First we get the count
	queue_family_count: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
	if queue_family_count == 0 {
		return {}, false
	}

	// Make the empty array with the count
	queue_families := make(
		[]vk.QueueFamilyProperties,
		int(queue_family_count),
		context.temp_allocator,
	)
	defer delete(queue_families, context.temp_allocator)

	// Then we pass the array ptr to populate it..
	vk.GetPhysicalDeviceQueueFamilyProperties(
		device,
		&queue_family_count,
		raw_data(queue_families),
	)

	families := QueueFamilyIndices{}
	found_gfx, found_present := false, false

	// Then we loop it to get the families idxs
	for i in 0 ..< int(queue_family_count) {
		q := queue_families[i]
		if q.queueCount > 0 {
			if .GRAPHICS in q.queueFlags {
				families.graphics_family = u32(i)
				found_gfx = true
			}

			if vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), surface, nil) == .SUCCESS {
				families.present_family = u32(i)
				found_present = true
			}
		}
	}

	if !found_gfx || !found_present {
		return {}, false
	}

	return families, true
}

device_extension_available :: proc(device: vk.PhysicalDevice, name: cstring) -> bool {
	count: u32 = 0
	if vk.EnumerateDeviceExtensionProperties(device, nil, &count, nil) != .SUCCESS || count == 0 {
		return false
	}

	props := make([]vk.ExtensionProperties, int(count), context.temp_allocator)
	defer delete(props, context.temp_allocator)

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

GpuContext :: struct {
	device:                vk.Device,
	graphics_queue:        vk.Queue,
	graphics_family_index: u32,
	present_queue:         vk.Queue,
	present_family_index:  u32,
}

create_gpu_context :: proc(
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
) -> (
	GpuContext,
	bool,
) {
	queue_families, ok := find_queue_families(physical_device, surface)
	if !ok {
		return {}, false
	}

	queue_priority: f32 = 1.0
	queue_create_infos := [2]vk.DeviceQueueCreateInfo {
		{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = queue_families.graphics_family,
			queueCount = 1,
			pQueuePriorities = &queue_priority,
		},
		{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = queue_families.present_family,
			queueCount = 1,
			pQueuePriorities = &queue_priority,
		},
	}

	// Specify the device extensions we need (swapchain is essencial for rendering)
	device_extensions := make([dynamic]cstring, context.temp_allocator)

	if device_extension_available(physical_device, vk.KHR_SWAPCHAIN_EXTENSION_NAME) {
		append(&device_extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
	}

	if device_extension_available(physical_device, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME) {
		append(&device_extensions, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME)
	}


	// Specify which physical device features we'll use
	// For a basic triangle, we leave everything at defaults (disabled)
	device_features := vk.PhysicalDeviceFeatures{}

	// For Vulkan 1.3 features like dynamic rendering, chain a features struct
	dynamic_rendering_feature := vk.PhysicalDeviceDynamicRenderingFeatures {
		dynamicRendering = true,
	}

	features2 := vk.PhysicalDeviceFeatures2 {
		sType    = .PHYSICAL_DEVICE_FEATURES_2,
		pNext    = &dynamic_rendering_feature,
		features = device_features,
	}

	create_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features2,
		queueCreateInfoCount    = len(queue_create_infos),
		pQueueCreateInfos       = raw_data(queue_create_infos[:]),
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions[:]),
	}

	device: vk.Device

	if vk.CreateDevice(physical_device, &create_info, nil, &device) != .SUCCESS {
		return {}, false
	}

	vk.load_proc_addresses_device(device)

	graphics_queue, present_queue: vk.Queue
	vk.GetDeviceQueue(device, queue_families.graphics_family, 0, &graphics_queue)
	vk.GetDeviceQueue(device, queue_families.present_family, 0, &present_queue)

	gpu_context := GpuContext {
		device                = device,
		graphics_queue        = graphics_queue,
		graphics_family_index = queue_families.graphics_family,
		present_queue         = present_queue,
		present_family_index  = queue_families.present_family,
	}

	return gpu_context, true
}

has_graphics_queue_family :: proc(device: vk.PhysicalDevice) -> bool {
	queue_family_count: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
	if queue_family_count == 0 {
		return false
	}

	queue_families := make(
		[]vk.QueueFamilyProperties,
		int(queue_family_count),
		context.temp_allocator,
	)
	defer delete(queue_families, context.temp_allocator)

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

pick_physical_device :: proc(
	instance: vk.Instance,
) -> (
	vk.PhysicalDevice,
	vk.PhysicalDeviceProperties,
	bool,
) {
	device_count: u32 = 0
	if vk.EnumeratePhysicalDevices(instance, &device_count, nil) != .SUCCESS || device_count == 0 {
		return {}, {}, false
	}

	devices := make([]vk.PhysicalDevice, int(device_count), context.temp_allocator)
	defer delete(devices, context.temp_allocator)

	if vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(devices)) != .SUCCESS {
		return {}, {}, false
	}

	best_score := -1
	device: vk.PhysicalDevice = nil
	props: vk.PhysicalDeviceProperties

	for d in devices {
		vk.GetPhysicalDeviceProperties(d, &props)
		if props.deviceType == .DISCRETE_GPU {
			device = d
			break
		}
	}

	if device == nil {
		return {}, {}, false
	}

	return device, props, true
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

instance_extension_available :: proc(name: cstring) -> bool {
	count: u32 = 0
	if vk.EnumerateInstanceExtensionProperties(nil, &count, nil) != .SUCCESS || count == 0 {
		return false
	}

	props := make([]vk.ExtensionProperties, int(count), context.temp_allocator)
	defer delete(props, context.temp_allocator)

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
// 3. create a vkDevice (logical device) [x]
// 4. specify which queue families to use [ ]
// 5. window (glfw)
// 6. vkSurfaceKHR & vkSwapchainKHR [KHR -> extension postfix]
// - Send the window handle from the OS to the vulkan api (WSI - Window System Interface)
// swap chain -> collection of render targets
main :: proc() {
	context.allocator, context.temp_allocator = memory_init()

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
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "NoEngine",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_4,
	}

	glfw_extensions := glfw.GetRequiredInstanceExtensions()
	extensions := make([dynamic]cstring, len(glfw_extensions))
	copy(extensions[:], glfw_extensions)

	portability_ext: cstring = vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
	enable_portability := instance_extension_available(portability_ext)
	append_portability_name :=
		enable_portability && !has_extension_name(glfw_extensions, portability_ext)

	if append_portability_name {
		append(&extensions, portability_ext)
	}

	append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	validation_layers: []cstring = {"VK_LAYER_KHRONOS_validation"}

	create_flags := vk.InstanceCreateFlags{}
	if enable_portability {
		create_flags = {.ENUMERATE_PORTABILITY_KHR}
	}

	create_info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		flags                   = create_flags,
		pApplicationInfo        = &app_info,
		enabledLayerCount       = u32(len(validation_layers)),
		ppEnabledLayerNames     = raw_data(validation_layers[:]),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions[:]),
	}

	instance: vk.Instance
	res_instance := vk.CreateInstance(&create_info, nil, &instance)
	if res_instance != .SUCCESS {
		log_error("vkCreateInstance failed:", res_instance)
		return
	}
	defer vk.DestroyInstance(instance, nil)
	vk.load_proc_addresses_instance(instance)

	physical_device, physical_device_props, ok_physical_device := pick_physical_device(instance)
	if !ok_physical_device {
		log_error("Failed to find a suitable GPU device")
		return
	}

	device_name := string(cast(cstring)&physical_device_props.deviceName[0])
	log_infof("Selected physical device %s", device_name)

	// Create the window
	window := glfw.CreateWindow(1280, 720, "Learning Vulkan", nil, nil)
	if window == nil {
		log_error("Failed to create a window")
		return
	}

	surface: vk.SurfaceKHR
	res_surface := glfw.CreateWindowSurface(instance, window, nil, &surface)
	if res_surface != .SUCCESS {
		log_error("glfw.CreateWindowSurface failed:", res_surface)
		return
	}

	device_and_queue, ok_device_queue := create_gpu_context(physical_device, surface)
	if !ok_device_queue {
		log_error("Failed to create logical device")
		return
	}
	defer vk.DestroyDevice(device_and_queue.device, nil)

	log_infof("Logical device created, graphics family=%d", device_and_queue.family_index)
	_ = device_and_queue.queue
}
