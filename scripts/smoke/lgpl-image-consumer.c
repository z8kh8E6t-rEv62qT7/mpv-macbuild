/* Integration probe: compile against the delivered SDK and decode via custom AVIO. */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavformat/avformat.h>
#include <libavutil/file.h>
#include <libswscale/swscale.h>

struct memory_input {
    uint8_t *data;
    int64_t size;
    int64_t position;
};

static int read_memory(void *opaque, uint8_t *buffer, int size)
{
    struct memory_input *input = opaque;
    int count = (int)FFMIN((int64_t)size, input->size - input->position);
    if (!count)
        return AVERROR_EOF;
    memcpy(buffer, input->data + input->position, count);
    input->position += count;
    return count;
}

static int64_t seek_memory(void *opaque, int64_t offset, int whence)
{
    struct memory_input *input = opaque;
    int64_t base;
    if (whence == AVSEEK_SIZE)
        return input->size;
    switch (whence & ~AVSEEK_FORCE) {
    case SEEK_SET: base = 0; break;
    case SEEK_CUR: base = input->position; break;
    case SEEK_END: base = input->size; break;
    default: return AVERROR(EINVAL);
    }
    if (offset < -base || offset > input->size - base)
        return AVERROR(EINVAL);
    input->position = base + offset;
    return input->position;
}

static int write_frames(AVCodecContext *decoder, AVFrame *frame, AVFrame *rgba,
                        SwsContext *scale, FILE *output, int *width, int *height, int *count)
{
    int ret;
    while ((ret = avcodec_receive_frame(decoder, frame)) >= 0) {
        if (*count && (frame->width != *width || frame->height != *height))
            return AVERROR_INVALIDDATA;
        *width = frame->width;
        *height = frame->height;
        av_frame_unref(rgba);
        rgba->width = *width;
        rgba->height = *height;
        rgba->format = AV_PIX_FMT_RGBA;
        rgba->colorspace = AVCOL_SPC_RGB;
        rgba->color_range = AVCOL_RANGE_JPEG;
        rgba->color_primaries = frame->color_primaries;
        rgba->color_trc = frame->color_trc;
        ret = sws_scale_frame(scale, rgba, frame);
        if (ret < 0)
            return ret;
        for (int row = 0; row < *height; row++) {
            size_t bytes = (size_t)*width * 4;
            if (fwrite(rgba->data[0] + row * rgba->linesize[0], 1, bytes, output) != bytes)
                return AVERROR(EIO);
        }
        av_frame_unref(frame);
        ++*count;
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

int main(int argc, char **argv)
{
    struct memory_input input = {0};
    size_t size = 0;
    AVFormatContext *format = NULL;
    AVIOContext *io = NULL;
    AVCodecContext *decoder = NULL;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL, *rgba = NULL;
    SwsContext *scale = NULL;
    FILE *output = NULL;
    uint8_t *buffer = NULL;
    const AVCodec *codec = NULL;
    int ret = AVERROR(ENOMEM), stream, width = 0, height = 0, count = 0;

    if (argc != 3)
        return 2;
    if (avformat_version() != LIBAVFORMAT_VERSION_INT || avcodec_version() != LIBAVCODEC_VERSION_INT ||
        avutil_version() != LIBAVUTIL_VERSION_INT || swscale_version() != LIBSWSCALE_VERSION_INT ||
        avfilter_version() != LIBAVFILTER_VERSION_INT) {
        fprintf(stderr, "SDK headers and runtime library versions differ\n");
        return 1;
    }
    ret = av_file_map(argv[1], &input.data, &size, 0, NULL);
    if (ret < 0)
        goto done;
    if (size > INT64_MAX) {
        ret = AVERROR(EINVAL);
        goto done;
    }
    input.size = (int64_t)size;
    format = avformat_alloc_context();
    buffer = av_malloc(4096);
    if (!format || !buffer) {
        ret = AVERROR(ENOMEM);
        goto done;
    }
    io = avio_alloc_context(buffer, 4096, 0, &input, read_memory, NULL, seek_memory);
    if (!io) {
        ret = AVERROR(ENOMEM);
        goto done;
    }
    buffer = NULL; /* Owned by io; libavformat may replace it. */
    format->pb = io;
    format->flags |= AVFMT_FLAG_CUSTOM_IO;
    if ((ret = avformat_open_input(&format, NULL, NULL, NULL)) < 0 ||
        (ret = avformat_find_stream_info(format, NULL)) < 0)
        goto done;
    stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (stream < 0) {
        ret = stream;
        goto done;
    }
    decoder = avcodec_alloc_context3(codec);
    packet = av_packet_alloc();
    frame = av_frame_alloc();
    rgba = av_frame_alloc();
    scale = sws_alloc_context();
    if (!decoder || !packet || !frame || !rgba || !scale) {
        ret = AVERROR(ENOMEM);
        goto done;
    }
    if ((ret = avcodec_parameters_to_context(decoder, format->streams[stream]->codecpar)) < 0 ||
        (ret = avcodec_open2(decoder, codec, NULL)) < 0)
        goto done;
    output = fopen(argv[2], "wb");
    if (!output) {
        ret = AVERROR(errno);
        goto done;
    }
    while ((ret = av_read_frame(format, packet)) >= 0) {
        if (packet->stream_index == stream) {
            ret = avcodec_send_packet(decoder, packet);
            if (ret >= 0)
                ret = write_frames(decoder, frame, rgba, scale, output, &width, &height, &count);
        }
        av_packet_unref(packet);
        if (ret < 0)
            goto done;
    }
    if (ret != AVERROR_EOF)
        goto done;
    ret = avcodec_send_packet(decoder, NULL);
    if (ret >= 0)
        ret = write_frames(decoder, frame, rgba, scale, output, &width, &height, &count);
    if (ret >= 0 && !count)
        ret = AVERROR_INVALIDDATA;
    if (ret >= 0)
        printf("%d %d %d\n", width, height, count);

done:
    if (output && fclose(output) && ret >= 0)
        ret = AVERROR(EIO);
    av_packet_free(&packet);
    av_frame_free(&frame);
    av_frame_free(&rgba);
    sws_freeContext(scale);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
    if (io)
        av_freep(&io->buffer);
    avio_context_free(&io);
    av_free(buffer);
    av_file_unmap(input.data, size);
    if (ret < 0)
        fprintf(stderr, "image decode failed: %s\n", av_err2str(ret));
    return ret < 0;
}
