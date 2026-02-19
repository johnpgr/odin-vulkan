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
main :: proc() {
	memory: Memory_System
	memory_system_initialize(&memory)
	defer memory_system_shutdown(&memory)

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
	defer vk.DestroyInstance(instance, nil)

	vk.load_proc_addresses_instance(instance)

	log_info("Vulkan instance created!")
}
