package main

import "core:mem"
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
	found_gfx: b32 = false
	found_present: b32 = false

	// Then we loop it to get the families idxs
	for i in 0 ..< int(queue_family_count) {
		q := queue_families[i]
		if q.queueCount > 0 {
			if .GRAPHICS in q.queueFlags {
				families.graphics_family = u32(i)
				found_gfx = true
			}

			if !found_present {
				vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(i), surface, &found_present)
				if found_present {
					families.present_family = u32(i)
				}
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
	queue_create_infos: [2]vk.DeviceQueueCreateInfo
	queue_create_info_count: u32 = 1

	queue_create_infos[0] = vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = queue_families.graphics_family,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}

	if queue_families.present_family != queue_families.graphics_family {
		queue_create_infos[1] = vk.DeviceQueueCreateInfo {
			sType            = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = queue_families.present_family,
			queueCount       = 1,
			pQueuePriorities = &queue_priority,
		}
		queue_create_info_count = 2
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
		sType            = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
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
		queueCreateInfoCount    = queue_create_info_count,
		pQueueCreateInfos       = &queue_create_infos[0],
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

SwapchainContext :: struct {
	handle:       vk.SwapchainKHR,
	images:       []vk.Image,
	image_views:  []vk.ImageView,
	image_format: vk.Format,
	extent:       vk.Extent2D,
}

// Query the surface capabilities to decide the
// image format, resolution, and present mode
// then create the swap chain.
create_swapchain_context :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	indices: QueueFamilyIndices,
	swapchain_allocator: mem.Allocator,
) -> (
	SwapchainContext,
	bool,
) {
	// Get the capabilities
	capabilities: vk.SurfaceCapabilitiesKHR
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &capabilities) !=
	   .SUCCESS {
		return {}, false
	}

	// Get the formats
	format_count: u32 = 0
	if vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, nil) !=
	   .SUCCESS {
		return {}, false
	}

	formats := make([]vk.SurfaceFormatKHR, int(format_count), context.temp_allocator)
	defer delete(formats, context.temp_allocator)

	if vk.GetPhysicalDeviceSurfaceFormatsKHR(
		   physical_device,
		   surface,
		   &format_count,
		   raw_data(formats),
	   ) !=
	   .SUCCESS {
		return {}, false
	}

	// Get the present modes
	present_mode_count: u32 = 0
	if vk.GetPhysicalDeviceSurfacePresentModesKHR(
		   physical_device,
		   surface,
		   &present_mode_count,
		   nil,
	   ) !=
	   .SUCCESS {
		return {}, false
	}

	present_modes := make([]vk.PresentModeKHR, int(present_mode_count), context.temp_allocator)
	defer delete(present_modes, context.temp_allocator)

	if vk.GetPhysicalDeviceSurfacePresentModesKHR(
		   physical_device,
		   surface,
		   &present_mode_count,
		   raw_data(present_modes),
	   ) !=
	   .SUCCESS {
		return {}, false
	}

	// Choose a surface format - prefer SRGB w/ B8G8R8A8 layout
	chosen_format := formats[0] // fallback
	for f in formats {
		if f.format == .B8G8R8A8_SRGB && f.colorSpace == .SRGB_NONLINEAR {
			chosen_format = f
			break
		}
	}

	// Choose present mode - prefer mailbox (triple buffering) if available
	chosen_present_mode: vk.PresentModeKHR = .FIFO
	for p in present_modes {
		if p == .MAILBOX {
			chosen_present_mode = p
			break
		}
	}

	// Choose extent (resolution)
	swap_extent := capabilities.currentExtent

	// Request one more image than the minimum for smooth operation
	image_count := capabilities.minImageCount + 1
	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.maxImageCount
	}

	swapchain_create_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		// Target window surface the swapchain presents to.
		surface          = surface,
		// Number of images to keep in the swapchain.
		minImageCount    = image_count,
		// Pixel format of swapchain images.
		imageFormat      = chosen_format.format,
		// Color space used for presentation output.
		imageColorSpace  = chosen_format.colorSpace,
		// Resolution of each swapchain image.
		imageExtent      = swap_extent,
		// Layers per image (1 for regular 2D rendering).
		imageArrayLayers = 1,
		// Intended usage of swapchain images.
		imageUsage       = {.COLOR_ATTACHMENT},
		// Queue ownership mode for image access.
		imageSharingMode = .EXCLUSIVE,
		// Transform applied when presenting (e.g., rotation).
		preTransform     = capabilities.currentTransform,
		// How alpha is blended with the window system.
		compositeAlpha   = {.OPAQUE},
		// Presentation pacing strategy (vsync/latency behavior).
		presentMode      = chosen_present_mode,
		// Ignore rendering to pixels hidden by other windows.
		clipped          = true,
	}

	if indices.graphics_family != indices.present_family {
		family_indices := []u32{indices.graphics_family, indices.present_family}
		swapchain_create_info.imageSharingMode = .CONCURRENT
		swapchain_create_info.queueFamilyIndexCount = 2
		swapchain_create_info.pQueueFamilyIndices = raw_data(family_indices)
	}

	swapchain: vk.SwapchainKHR
	if vk.CreateSwapchainKHR(device, &swapchain_create_info, nil, &swapchain) != .SUCCESS {
		return {}, false
	}

	swapchain_image_count: u32 = 0
	if vk.GetSwapchainImagesKHR(device, swapchain, &swapchain_image_count, nil) != .SUCCESS {
		vk.DestroySwapchainKHR(device, swapchain, nil)
		return {}, false
	}

	swapchain_images := make([]vk.Image, int(swapchain_image_count), swapchain_allocator)
	if vk.GetSwapchainImagesKHR(
		   device,
		   swapchain,
		   &swapchain_image_count,
		   raw_data(swapchain_images),
	   ) !=
	   .SUCCESS {
		vk.DestroySwapchainKHR(device, swapchain, nil)
		return {}, false
	}

	swapchain_image_views := make([]vk.ImageView, len(swapchain_images), swapchain_allocator)
	created_image_views := 0

	for image in swapchain_images {
		view_create_info := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = image,
			viewType = .D2,
			format = chosen_format.format,
			components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}

		image_view: vk.ImageView
		if vk.CreateImageView(device, &view_create_info, nil, &image_view) != .SUCCESS {
			for created_index in 0 ..< created_image_views {
				vk.DestroyImageView(device, swapchain_image_views[created_index], nil)
			}
			vk.DestroySwapchainKHR(device, swapchain, nil)
			return {}, false
		}
		swapchain_image_views[created_image_views] = image_view
		created_image_views += 1
	}

	swapchain_context := SwapchainContext {
		handle       = swapchain,
		images       = swapchain_images,
		image_views  = swapchain_image_views,
		image_format = chosen_format.format,
		extent       = swap_extent,
	}
	return swapchain_context, true
}

destroy_swapchain_context :: proc(device: vk.Device, swapchain_context: ^SwapchainContext) {
	if len(swapchain_context.image_views) > 0 {
		for image_view in swapchain_context.image_views {
			vk.DestroyImageView(device, image_view, nil)
		}
	}
	if len(swapchain_context.images) > 0 {
		vk.DestroySwapchainKHR(device, swapchain_context.handle, nil)
	}
	swapchain_context^ = {}
}

recreate_swapchain :: proc(
	device: vk.Device,
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	indices: QueueFamilyIndices,
	swapchain_allocator: mem.Allocator,
	swapchain_context: ^SwapchainContext,
) -> bool {
	vk.DeviceWaitIdle(device)
	destroy_swapchain_context(device, swapchain_context)
	swapchain_memory_reset(swapchain_allocator)

	new_swapchain_context, ok_swapchain := create_swapchain_context(
		device,
		physical_device,
		surface,
		indices,
		swapchain_allocator,
	)
	if !ok_swapchain {
		return false
	}

	swapchain_context^ = new_swapchain_context
	return true
}

// To render the initial triangle w/ Vulkan:
// 1. get the vkInstance [x]
// 2. query it to get a vkPhysicalDevice [x]
// 3. create a vkDevice (logical device) [x]
// 4. specify which queue families to use [x]
// 5. window (glfw) [x]
// 6. vkSurfaceKHR & vkSwapchainKHR [KHR -> extension postfix] [ ]
// 7. Graphics pipeline
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
	if vk.CreateInstance(&create_info, nil, &instance) != .SUCCESS {
		log_error("vkCreateInstance failed")
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
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	window := glfw.CreateWindow(1280, 720, "Learning Vulkan", nil, nil)
	if window == nil {
		log_error("Failed to create a window")
		return
	}
	defer glfw.DestroyWindow(window)

	surface: vk.SurfaceKHR
	if glfw.CreateWindowSurface(instance, window, nil, &surface) != .SUCCESS {
		log_error("glfw.CreateWindowSurface failed")
		return
	}
	defer vk.DestroySurfaceKHR(instance, surface, nil)

	gpu_context, ok_gpu_context := create_gpu_context(physical_device, surface)
	if !ok_gpu_context {
		log_error("Failed to create logical device")
		return
	}
	defer vk.DestroyDevice(gpu_context.device, nil)

	queue_family_indices, ok_queue_families := find_queue_families(physical_device, surface)
	if !ok_queue_families {
		log_error("Failed to find swapchain queue families")
		return
	}

	swapchain_allocator := swapchain_memory_init()
	swapchain_context, ok_swapchain := create_swapchain_context(
		gpu_context.device,
		physical_device,
		surface,
		queue_family_indices,
		swapchain_allocator,
	)
	if !ok_swapchain {
		swapchain_memory_reset(swapchain_allocator)
		log_error("Failed to create swapchain context")
		return
	}
	defer {
		vk.DeviceWaitIdle(gpu_context.device)
		destroy_swapchain_context(gpu_context.device, &swapchain_context)
		swapchain_memory_reset(swapchain_allocator)
	}

	log_infof("Logical device created, graphics family=%d", gpu_context.graphics_family_index)
	log_infof("Swapchain created with %d images", len(swapchain_context.images))
}
