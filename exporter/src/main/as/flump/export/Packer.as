//
// Flump - Copyright 2012 Three Rings Design

package flump.export {

import com.threerings.util.Comparators;
import com.threerings.util.Log;

import flash.geom.Point;
import flash.utils.getTimer;

import flump.SwfTexture;
import flump.mold.KeyframeMold;
import flump.mold.MovieMold;
import flump.xfl.XflLibrary;
import flump.xfl.XflTexture;

public class Packer
{
    public const atlases :Vector.<Atlas> = new Vector.<Atlas>();

    public function Packer (lib :XflLibrary, scale :Number = 1.0, maxSize :int = 2048,
        prefix :String = "", suffix :String = "") {

        _maxSize = maxSize;

        for each (var tex :XflTexture in lib.textures) {
            _unpacked.push(SwfTexture.fromTexture(lib.swf, tex, scale));
        }
        for each (var movie :MovieMold in lib.movies) {
            if (!movie.flipbook) continue;
            for each (var kf :KeyframeMold in movie.layers[0].keyframes) {
                _unpacked.push(SwfTexture.fromFlipbook(lib, movie, kf.index, scale));
            }
        }
        _unpacked.sort(Comparators.createReverse(Comparators.createFields(["a", "w", "h"])));

        var start :int = flash.utils.getTimer();
        while (_unpacked.length > 0) {
            // Add a new atlas
            const size :Point = findOptimalSize();
            atlases.push(new AtlasImpl(prefix + "atlas" + atlases.length + suffix, size.x, size.y));

            // Try to pack each texture into any atlas
            for (var ii :int = 0; ii < _unpacked.length; ++ii) {
                var unpacked :SwfTexture = _unpacked[ii];

                if (unpacked.w > _maxSize || unpacked.h > _maxSize) {
                    throw new Error("Too large to fit in an atlas: " + unpacked.w + ", " + unpacked.h + " " + unpacked.symbol);
                }

                for each (var atlas :AtlasImpl in atlases) {
                    // TODO(bruno): Support rotated textures?
                    if (atlas.place(unpacked)) {
                        _unpacked.splice(ii--, 1);
                        break;
                    }
                }
            }
        }

        var totalTime :int = flash.utils.getTimer() - start;
        log.info("Finished packing", "scale", scale, "time", totalTime / 1000);
    }

    // Estimate the optimal size for the next atlas
    protected function findOptimalSize () :Point {
        var area :int = 0;
        var maxW :int = 0;
        var maxH :int = 0;

        for each (var tex :SwfTexture in _unpacked) {
            const w :int = tex.w + AtlasImpl.PADDING;
            const h :int = tex.h + AtlasImpl.PADDING;
            area += w * h;
            maxW = Math.max(maxW, w);
            maxH = Math.max(maxH, h);
        }

        const size :Point = new Point(nextPowerOfTwo(maxW), nextPowerOfTwo(maxH));

        // Double the area until it's big enough
        while (size.x * size.y < area) {
            if (size.x < size.y) size.x *= 2;
            else size.y *= 2;
        }

        size.x = Math.min(size.x, _maxSize);
        size.y = Math.min(size.y, _maxSize);

        return size;
    }

    protected static function nextPowerOfTwo (n :int) :int {
        var p :int = 1;
        while (p < n) p *= 2;
        return p;
    }

    protected var _maxSize :int;

    protected const _unpacked :Vector.<SwfTexture> = new Vector.<SwfTexture>();

    private static const log :Log = Log.getLog(Packer);
}
}

import com.adobe.images.PNGEncoder;
import com.threerings.util.Arrays;

import flash.display.Bitmap;
import flash.display.BitmapData;
import flash.display.Sprite;
import flash.geom.Point;
import flash.geom.Rectangle;
import flash.utils.IDataOutput;

import flump.SwfTexture;
import flump.Util;
import flump.export.Atlas;
import flump.mold.AtlasMold;
import flump.mold.AtlasTextureMold;

class AtlasImpl
    implements Atlas
{
    // The empty border size around the right and bottom edges of each texture, to prevent bleeding
    public static const PADDING :int = 2;

    public var name :String;

    public function AtlasImpl (name :String, w :int, h :int) {
        this.name = name;
        _width = w;
        _height = h;
        _mask = Arrays.create(_width * _height, false);
    }

    public function get area () :int { return _width * _height; }

    public function get filename () :String { return name + ".png"; }

    public function get used () :int {
        var used :int = 0;
        _nodes.forEach(function (n :Node, ..._) :void { used += n.bounds.width * n.bounds.height; });
        return used;
    }

    public function writePNG (bytes :IDataOutput) :void {
        var constructed :Sprite = new Sprite();
        _nodes.forEach(function (node :Node, ..._) :void {
            const tex :SwfTexture = node.texture;
            const bm :Bitmap = new Bitmap(node.texture.toBitmapData(), "auto", true);
            constructed.addChild(bm);
            bm.x = node.bounds.x;
            bm.y = node.bounds.y;
        });
        const bd :BitmapData = Util.renderToBitmapData(constructed, _width, _height);
        bytes.writeBytes(PNGEncoder.encode(bd));
    }

    public function toMold () :AtlasMold {
        const mold :AtlasMold = new AtlasMold();
        mold.file = name + ".png";
        _nodes.forEach(function (node :Node, ..._) :void {
            const tex :SwfTexture = node.texture;
            const texMold :AtlasTextureMold = new AtlasTextureMold();
            texMold.symbol = tex.symbol;
            texMold.bounds = new Rectangle(node.bounds.x, node.bounds.y, tex.w, tex.h);
            texMold.offset = new Point(tex.offset.x, tex.offset.y);
            mold.textures.push(texMold);
        });
        return mold;
    }

    // Try to place a texture in this atlas, return true if it fit
    public function place (tex :SwfTexture) :Boolean {
        var w :int = tex.w + PADDING;
        var h :int = tex.h + PADDING;
        if (w > _width || h > _height) {
            return false;
        }

        var found :Boolean = false;
        for (var yy :int = 0; yy <= _height - h && !found; ++yy) {
            for (var xx :int = 0; xx <= _width - w; ++xx) {
                // if our right-most pixel is masked, jump ahead by that much
                if (maskAt(xx + w - 1, yy)) {
                    xx += w;
                    continue;
                }

                if (!isMasked(xx, yy, w, h)) {
                    _nodes.push(new Node(xx, yy, tex));
                    setMasked(xx, yy, w, h);
                    found = true;
                    break;
                }
            }
        }

        return found;
    }

    protected function isMasked (x :int, y :int, w :int, h :int) :Boolean {
        var xMax :int = x + w - 1;
        var yMax :int = y + h - 1;
        // fail fast on extents
        if (maskAt(x, y) || maskAt(x, yMax) || maskAt(xMax, y) || maskAt(xMax, yMax)) {
            return true;
        }

        for (var yy :int = y + 1; yy < yMax; ++yy) {
            for (var xx :int = x + 1; xx < xMax; ++xx) {
                if (maskAt(xx, yy)) {
                    return true;
                }
            }
        }
        return false;
    }

    protected function setMasked (x :int, y :int, w: int, h :int) :void {
        for (var yy :int = y; yy < y + h; ++yy) {
            for (var xx :int = x; xx < x + w; ++xx) {
                _mask[(yy * _width) + xx] = true;
            }
        }
    }

    protected function maskAt (xx :int, yy :int) :Boolean {
        return _mask[(yy * _width) + xx];
    }

    protected var _nodes :Array = [];
    protected var _width :int;
    protected var _height :int;
    protected var _mask :Array;
}

class Node
{
    public var bounds :Rectangle;
    public var texture :SwfTexture;

    public function Node (x :int, y :int, texture :SwfTexture) {
        this.texture = texture;
        this.bounds = new Rectangle(x, y, texture.w, texture.h);
    }
}
