import * as THREE from 'three/webgpu';
import { initThreeContext } from '../../src/app/three-context';
import { UnifiedModelLoader } from '../../src/app/unified-model-loader';
import { GaussianModel } from '../../src/app/GaussianModel';
import {
	initOrtEnvironment,
	getDefaultOrtWasmPaths,
} from '../../src/config/ort-config';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

async function main() {
	const statusDiv = document.getElementById('status')!;
	const fileInput = document.getElementById('splat-file') as HTMLInputElement;
	const container = document.getElementById('canvas-container')!;

	// 1. Initialize ONNX Runtime environment
	try {
		const wasmPaths = getDefaultOrtWasmPaths();
		// Adjust paths for demo folder if necessary, or ensure they are served correctly
		// Default might be /src/ort/ which works if served from root
		initOrtEnvironment(wasmPaths);
		console.log('ORT initialized');
	} catch (e) {
		console.warn('ORT initialization failed:', e);
	}

	// 2. Create Canvas and Renderer
	const canvas = document.createElement('canvas');
	canvas.style.width = '100%';
	canvas.style.height = '100%';
	container.appendChild(canvas);

	const renderer = await initThreeContext(canvas);
	if (!renderer) {
		statusDiv.textContent = 'Failed to initialize WebGPU renderer';
		return;
	}
	renderer.setClearColor(0x000000, 1);
	renderer.setSize(window.innerWidth, window.innerHeight);

	// 3. Create Scene and Camera
	const scene = new THREE.Scene();

	// Add some lights (though Splats are usually self-illuminated, this helps for other models)
	const ambientLight = new THREE.AmbientLight(0xffffff, 0.5);
	scene.add(ambientLight);

	const camera = new THREE.PerspectiveCamera(
		75,
		window.innerWidth / window.innerHeight,
		0.1,
		1000,
	);
	camera.position.set(0, 0, 5);

	// 4. Controls
	const controls = new OrbitControls(camera, canvas);
	controls.enableDamping = true;

	// 5. Unified Model Loader
	const loader = new UnifiedModelLoader(renderer, scene);

	// 6. Handle File Input
	fileInput.addEventListener('change', async (event) => {
		const file = (event.target as HTMLInputElement).files?.[0];
		if (!file) return;

		statusDiv.textContent = `Loading ${file.name}...`;

		try {
			// Clear previous models if any (basic cleanup)
			// Ideally we should traverse scene and dispose, but for min demo we just load new

			const result = await loader.loadModel(file);

			statusDiv.textContent = `Loaded ${file.name} (${result.info.count} splats)`;
			console.log('Load result:', result);

			// Center camera on model
			if (result.models.length > 0) {
				const model = result.models[0];
				let center = new THREE.Vector3(0, 0, 0);
				let size = 5.0;

				if (model instanceof GaussianModel) {
					// Use GaussianModel's AABB if available
					const aabb = model.getWorldAABB();
					if (aabb) {
						const min = new THREE.Vector3(
							aabb.min[0],
							aabb.min[1],
							aabb.min[2],
						);
						const max = new THREE.Vector3(
							aabb.max[0],
							aabb.max[1],
							aabb.max[2],
						);
						center.addVectors(min, max).multiplyScalar(0.5);
						size = min.distanceTo(max);
						console.log(
							'Gaussian AABB:',
							min,
							max,
							'Center:',
							center,
							'Size:',
							size,
						);
					}
				} else {
					// Use Three.js Box3 for other models
					const box = new THREE.Box3().setFromObject(model);
					if (!box.isEmpty()) {
						box.getCenter(center);
						const boxSize = new THREE.Vector3();
						box.getSize(boxSize);
						size = boxSize.length();
						console.log('Mesh Box3:', box, 'Center:', center, 'Size:', size);
					}
				}

				// Adjust camera
				// Move camera to look at center from a distance
				const distance = size * 0.8; // Reasonable distance
				const direction = new THREE.Vector3(0, 0, 1).applyQuaternion(
					camera.quaternion,
				);
				camera.position.copy(center).add(direction.multiplyScalar(distance));
				controls.target.copy(center);
				controls.update();

				console.log('Camera positioned at:', camera.position);
				console.log('Controls target at:', controls.target);
			}
		} catch (error: any) {
			console.error('Load error:', error);
			statusDiv.textContent = `Error: ${error.message}`;
		}
	});

	// 7. Render Loop
	window.addEventListener('resize', () => {
		camera.aspect = window.innerWidth / window.innerHeight;
		camera.updateProjectionMatrix();
		renderer.setSize(window.innerWidth, window.innerHeight);
	});

	renderer.setAnimationLoop(() => {
		controls.update();
		renderer.render(scene, camera);
	});
}

main().catch(console.error);
