// @ts-ignore
// import { WebGPURenderer } from 'three/webgpu'
import { useEffect, useState } from 'react'
// import { Canvas, useThree, extend, ReactThreeFiber } from '@react-three/fiber'
import { useThree, extend, ReactThreeFiber } from '@react-three/fiber'
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js'
import './App.css'
import { Box } from '@react-three/drei'
import { AsyncWebGPUCanvas } from './components/AsyncWebGPUCanvas'


function App() {
  // const renderer = new WebGPURenderer({ antialias: true });
  return (
		<div style={{ width: '100vw', height: '100vh' }}>
			<AsyncWebGPUCanvas
				// frameloop="never"
				// gl={renderer}
				onCreated={({ gl }) => {
					// 设置渲染器的大小
					gl.setSize(window.innerWidth, window.innerHeight);
					// 如果需要，可以进一步配置渲染器
				}}
				camera={{ position: [0, 0, 5] }}
			>
				<ambientLight intensity={0.5} />
				<spotLight position={[10, 10, 10]} angle={0.15} penumbra={1} />
				<pointLight position={[-10, -10, -10]} />
				<gridHelper args={[10, 10]} />
				<Box position={[-1.2, 0, 0]} />
				<Box position={[1.2, 0, 0]} />
			</AsyncWebGPUCanvas>
		</div>
	);
}

export default App
