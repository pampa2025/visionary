import React, { useState, useEffect } from 'react';
import './App.css';
import { Box, OrbitControls } from '@react-three/drei';
import { AsyncWebGPUCanvas } from './components/AsyncWebGPUCanvas';
import { StatsMonitor } from './components/StatsMonitor';
import { VisionaryRenderer } from './components/VisionaryRenderer';
import { Splat } from './components/Splat';

// Enable Visionary debug logs
(globalThis as any).GS_DEBUG_FLAG = true;
(globalThis as any).GS_VIDEO_EXPORT_DEBUG = true;

function App() {
	// Example state for a splat model URL
	// Replace this with a valid .ply or .splat URL served by your dev server
	const [splatUrl, setSplatUrl] = useState<string | null>(null);

	return (
		<div style={{ width: '100vw', height: '100vh' }}>
			<AsyncWebGPUCanvas camera={{ position: [0, 0, 5] }}>
				{/* VisionaryRenderer initializes the engine and provides context */}
				<VisionaryRenderer>
					<ambientLight intensity={0.5} />
					<spotLight position={[10, 10, 10]} angle={0.15} penumbra={1} />
					<pointLight position={[-10, -10, -10]} />
					<gridHelper args={[10, 10]} />

					{/* Standard R3F objects work alongside */}
					<Box position={[-1.2, 0, 0]}>
						<meshStandardMaterial color="orange" />
					</Box>
					<Box position={[1.2, 0, 0]}>
						<meshStandardMaterial color="hotpink" />
					</Box>

					{/* Declarative Splat component */}
					{splatUrl && <Splat src={splatUrl} position={[0, 1, 0]} scale={1} />}
					{/* <Splat
						src={'/models/point_cloud_3.ply'}
						position={[0, -1, 0]}
						scale={1}
					/> */}
					<OrbitControls />
					<StatsMonitor />
				</VisionaryRenderer>
			</AsyncWebGPUCanvas>

			{/* Simple UI to load a model */}
			<div
				style={{
					position: 'absolute',
					top: 20,
					left: 20,
					background: 'rgba(0,0,0,0.7)',
					padding: 20,
					borderRadius: 8,
					color: 'white',
				}}
			>
				<h3>Visionary R3F Integration</h3>
				<p>WebGPU + ONNX Runtime Ready</p>
				<div style={{ display: 'flex', gap: 10 }}>
					<input
						type="text"
						placeholder="Path to .ply/.splat"
						style={{ padding: 8, borderRadius: 4, border: 'none' }}
						onKeyDown={(e) => {
							if (e.key === 'Enter') {
								setSplatUrl(e.currentTarget.value);
							}
						}}
					/>
					<button onClick={() => setSplatUrl('/models/point_cloud_3.ply')}>
						Load Demo
					</button>
				</div>
			</div>
		</div>
	);
}

export default App;
